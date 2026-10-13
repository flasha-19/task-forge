// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TaskForge
/// @notice Minimal onchain task marketplace. Creators escrow ERC-20 (USDC) rewards, contributors
///         submit work, creators accept one submission, and the contributor pulls the reward.
/// @dev Task state machine (all other transitions revert):
///        Open     -> Accepted   : creator accepts a submission (acceptSubmission)
///        Open     -> Cancelled  : creator cancels, see cancelTask for eligibility
///        Accepted -> Completed  : accepted contributor withdraws (withdrawReward)
///      Cancelled and Completed are terminal. "Expired" is not stored: it is derived from the
///      deadline (see isExpired) and only restricts new submissions.
contract TaskForge is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Open,
        Accepted,
        Completed,
        Cancelled
    }

    enum Category {
        Development,
        Frontend,
        SmartContract,
        Documentation,
        Research,
        Design,
        Other
    }

    struct Task {
        address creator;
        address contributor; // set on acceptance
        uint96 reward; // token base units
        uint64 deadline; // submissions close at this timestamp
        Category category;
        Status status;
        uint32 submissionCount;
        uint256 acceptedSubmissionId; // valid only when status is Accepted or Completed
        string title;
        string description;
    }

    struct Submission {
        uint256 taskId;
        address contributor;
        uint64 createdAt;
        string description;
        string url;
    }

    uint256 public constant MAX_TITLE_BYTES = 120;
    uint256 public constant MAX_DESCRIPTION_BYTES = 2000;
    uint256 public constant MAX_URL_BYTES = 300;
    uint256 public constant MAX_DURATION = 365 days;
    /// @notice After deadline + REVIEW_PERIOD the creator may reclaim funds even if submissions exist.
    uint256 public constant REVIEW_PERIOD = 7 days;

    IERC20 public immutable token;

    Task[] private _tasks; // task id = index
    Submission[] private _submissions; // submission id = index (global)
    mapping(uint256 taskId => uint256[] ids) private _taskSubmissionIds;
    mapping(uint256 taskId => mapping(address who => bool)) public hasSubmitted;

    /// @notice Sum of rewards for tasks in Open or Accepted state. Always <= token balance.
    uint256 public totalEscrowed;

    event TaskCreated(
        uint256 indexed taskId,
        address indexed creator,
        uint256 reward,
        uint64 deadline,
        Category category,
        string title
    );
    event SubmissionCreated(
        uint256 indexed taskId,
        uint256 indexed submissionId,
        address indexed contributor,
        string url
    );
    event SubmissionAccepted(
        uint256 indexed taskId, uint256 indexed submissionId, address indexed contributor
    );
    event RewardWithdrawn(uint256 indexed taskId, address indexed contributor, uint256 amount);
    event TaskCancelled(uint256 indexed taskId, address indexed creator, uint256 refund);

    error ZeroAddress();
    error InvalidTitle();
    error InvalidDescription();
    error InvalidUrl();
    error InvalidReward();
    error InvalidDeadline();
    error InvalidTransferAmount();
    error TaskNotFound();
    error SubmissionNotFound();
    error NotCreator();
    error NotContributor();
    error InvalidStatus(Status current);
    error TaskExpired();
    error CreatorCannotSubmit();
    error AlreadySubmitted();
    error SubmissionTaskMismatch();
    error CancelNotAllowed();

    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    // ------------------------------------------------------------------ writes

    /// @notice Create a task and escrow `reward` tokens. Caller must have approved this contract.
    function createTask(
        string calldata title,
        string calldata description,
        Category category,
        uint96 reward,
        uint64 deadline
    ) external nonReentrant returns (uint256 taskId) {
        if (bytes(title).length == 0 || bytes(title).length > MAX_TITLE_BYTES) {
            revert InvalidTitle();
        }
        if (bytes(description).length == 0 || bytes(description).length > MAX_DESCRIPTION_BYTES) {
            revert InvalidDescription();
        }
        if (reward == 0) revert InvalidReward();
        if (deadline <= block.timestamp || deadline > block.timestamp + MAX_DURATION) {
            revert InvalidDeadline();
        }

        taskId = _tasks.length;
        _tasks.push(
            Task({
                creator: msg.sender,
                contributor: address(0),
                reward: reward,
                deadline: deadline,
                category: category,
                status: Status.Open,
                submissionCount: 0,
                acceptedSubmissionId: 0,
                title: title,
                description: description
            })
        );
        totalEscrowed += reward;

        // Interaction last; reject fee-on-transfer / short-paying tokens so escrow is exact.
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), reward);
        if (token.balanceOf(address(this)) - balBefore != reward) revert InvalidTransferAmount();

        emit TaskCreated(taskId, msg.sender, reward, deadline, category, title);
    }

    /// @notice Submit work for an open, non-expired task. One submission per address per task.
    function submitWork(uint256 taskId, string calldata description, string calldata url)
        external
        returns (uint256 submissionId)
    {
        Task storage t = _task(taskId);
        if (t.status != Status.Open) revert InvalidStatus(t.status);
        if (block.timestamp > t.deadline) revert TaskExpired();
        if (msg.sender == t.creator) revert CreatorCannotSubmit();
        if (hasSubmitted[taskId][msg.sender]) revert AlreadySubmitted();
        if (bytes(description).length == 0 || bytes(description).length > MAX_DESCRIPTION_BYTES) {
            revert InvalidDescription();
        }
        if (bytes(url).length == 0 || bytes(url).length > MAX_URL_BYTES) revert InvalidUrl();

        hasSubmitted[taskId][msg.sender] = true;
        submissionId = _submissions.length;
        _submissions.push(
            Submission({
                taskId: taskId,
                contributor: msg.sender,
                createdAt: uint64(block.timestamp),
                description: description,
                url: url
            })
        );
        _taskSubmissionIds[taskId].push(submissionId);
        t.submissionCount += 1;

        emit SubmissionCreated(taskId, submissionId, msg.sender, url);
    }

    /// @notice Creator accepts one submission. Reward becomes withdrawable by that contributor.
    function acceptSubmission(uint256 taskId, uint256 submissionId) external {
        Task storage t = _task(taskId);
        if (msg.sender != t.creator) revert NotCreator();
        if (t.status != Status.Open) revert InvalidStatus(t.status);
        if (submissionId >= _submissions.length) revert SubmissionNotFound();
        Submission storage s = _submissions[submissionId];
        if (s.taskId != taskId) revert SubmissionTaskMismatch();

        t.status = Status.Accepted;
        t.acceptedSubmissionId = submissionId;
        t.contributor = s.contributor;

        emit SubmissionAccepted(taskId, submissionId, s.contributor);
    }

    /// @notice Accepted contributor pulls the reward. Pays exactly once.
    function withdrawReward(uint256 taskId) external nonReentrant {
        Task storage t = _task(taskId);
        if (t.status != Status.Accepted) revert InvalidStatus(t.status);
        if (msg.sender != t.contributor) revert NotContributor();

        uint256 amount = t.reward;
        t.status = Status.Completed; // effects before interaction
        totalEscrowed -= amount;

        token.safeTransfer(msg.sender, amount);
        emit RewardWithdrawn(taskId, msg.sender, amount);
    }

    /// @notice Creator cancels an Open task and gets the escrowed reward back.
    /// @dev Eligible when (a) there are no submissions, or (b) the deadline plus REVIEW_PERIOD has
    ///      passed without acceptance. Accepted tasks can never be cancelled, so an accepted
    ///      contributor's reward is always protected.
    function cancelTask(uint256 taskId) external nonReentrant {
        Task storage t = _task(taskId);
        if (msg.sender != t.creator) revert NotCreator();
        if (t.status != Status.Open) revert InvalidStatus(t.status);
        if (t.submissionCount != 0 && block.timestamp <= uint256(t.deadline) + REVIEW_PERIOD) {
            revert CancelNotAllowed();
        }

        uint256 amount = t.reward;
        t.status = Status.Cancelled;
        totalEscrowed -= amount;

        token.safeTransfer(msg.sender, amount);
        emit TaskCancelled(taskId, msg.sender, amount);
    }

    // ------------------------------------------------------------------- views

    function taskCount() external view returns (uint256) {
        return _tasks.length;
    }

    function submissionCount() external view returns (uint256) {
        return _submissions.length;
    }

    function getTask(uint256 taskId) external view returns (Task memory) {
        return _task(taskId);
    }

    /// @notice Paginated task listing (ids offset .. offset+limit-1).
    function getTasks(uint256 offset, uint256 limit) external view returns (Task[] memory out) {
        uint256 total = _tasks.length;
        if (offset >= total) return new Task[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        out = new Task[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            out[i - offset] = _tasks[i];
        }
    }

    function getSubmission(uint256 submissionId) external view returns (Submission memory) {
        if (submissionId >= _submissions.length) revert SubmissionNotFound();
        return _submissions[submissionId];
    }

    /// @notice Paginated submissions for a task, returned with their global ids.
    function getTaskSubmissions(uint256 taskId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, Submission[] memory subs)
    {
        _task(taskId);
        uint256[] storage all = _taskSubmissionIds[taskId];
        uint256 total = all.length;
        if (offset >= total) return (new uint256[](0), new Submission[](0));
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        subs = new Submission[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            ids[i - offset] = all[i];
            subs[i - offset] = _submissions[all[i]];
        }
    }

    function isExpired(uint256 taskId) external view returns (bool) {
        Task storage t = _task(taskId);
        return t.status == Status.Open && block.timestamp > t.deadline;
    }

    function withdrawableReward(uint256 taskId, address account) external view returns (uint256) {
        Task storage t = _task(taskId);
        return (t.status == Status.Accepted && t.contributor == account) ? t.reward : 0;
    }

    function canCancel(uint256 taskId) external view returns (bool) {
        Task storage t = _task(taskId);
        if (t.status != Status.Open) return false;
        return t.submissionCount == 0 || block.timestamp > uint256(t.deadline) + REVIEW_PERIOD;
    }

    function _task(uint256 taskId) private view returns (Task storage) {
        if (taskId >= _tasks.length) revert TaskNotFound();
        return _tasks[taskId];
    }
}
