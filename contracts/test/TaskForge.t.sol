// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TaskForge} from "../src/TaskForge.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @dev Token whose transfers can be switched to fail (return false) to test failure handling.
contract FlakyToken is MockUSDC {
    bool public failTransfers;

    function setFail(bool f) external {
        failTransfers = f;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (failTransfers) return false;
        return super.transfer(to, amt);
    }

    function transferFrom(address from, address to, uint256 amt) public override returns (bool) {
        if (failTransfers) return false;
        return super.transferFrom(from, to, amt);
    }
}

/// @dev Fee-on-transfer token: delivers 1% less than requested.
contract FeeToken is MockUSDC {
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev Token that calls back into the target on every outgoing transfer (hook-style reentrancy).
contract ReentrantToken is MockUSDC {
    address public target;
    bytes public payload;
    bool public armed;
    bool public reentryReverted;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        if (armed) {
            armed = false;
            (bool ok,) = target.call(payload);
            reentryReverted = !ok;
        }
        return super.transfer(to, amt);
    }
}

contract TaskForgeTest is Test {
    TaskForge forge_;
    MockUSDC usdc;

    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    uint96 constant REWARD = 100e6;
    string constant TITLE = "Fix issue #42";
    string constant DESC = "Please fix the bug";
    string constant URL = "https://github.com/org/repo/pull/1";

    event TaskCreated(
        uint256 indexed taskId,
        address indexed creator,
        uint256 reward,
        uint64 deadline,
        TaskForge.Category category,
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

    function setUp() public {
        usdc = new MockUSDC();
        forge_ = new TaskForge(IERC20(address(usdc)));
        usdc.mint(creator, 10_000e6);
        vm.prank(creator);
        usdc.approve(address(forge_), type(uint256).max);
    }

    function _create() internal returns (uint256) {
        vm.prank(creator);
        return forge_.createTask(
            TITLE, DESC, TaskForge.Category.Development, REWARD, uint64(block.timestamp + 7 days)
        );
    }

    function _submit(address who, uint256 taskId) internal returns (uint256) {
        vm.prank(who);
        return forge_.submitWork(taskId, "my work", URL);
    }

    // ---------------------------------------------------------------- create

    function test_CreateTask_EscrowsFunds() public {
        uint64 dl = uint64(block.timestamp + 7 days);
        vm.expectEmit(true, true, false, true);
        emit TaskCreated(0, creator, REWARD, dl, TaskForge.Category.Frontend, TITLE);
        vm.prank(creator);
        uint256 id = forge_.createTask(TITLE, DESC, TaskForge.Category.Frontend, REWARD, dl);

        TaskForge.Task memory t = forge_.getTask(id);
        assertEq(t.creator, creator);
        assertEq(t.reward, REWARD);
        assertEq(t.deadline, dl);
        assertEq(uint8(t.status), uint8(TaskForge.Status.Open));
        assertEq(usdc.balanceOf(address(forge_)), REWARD);
        assertEq(forge_.totalEscrowed(), REWARD);
        assertEq(forge_.taskCount(), 1);
    }

    function test_CreateTask_InsufficientBalance() public {
        vm.startPrank(stranger);
        usdc.approve(address(forge_), type(uint256).max);
        vm.expectRevert();
        forge_.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
    }

    function test_CreateTask_InsufficientAllowance() public {
        usdc.mint(stranger, REWARD);
        vm.prank(stranger);
        vm.expectRevert();
        forge_.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
    }

    function test_CreateTask_InvalidInputs() public {
        uint64 dl = uint64(block.timestamp + 1 days);
        vm.startPrank(creator);
        vm.expectRevert(TaskForge.InvalidTitle.selector);
        forge_.createTask("", DESC, TaskForge.Category.Other, REWARD, dl);

        vm.expectRevert(TaskForge.InvalidTitle.selector);
        forge_.createTask(string(new bytes(121)), DESC, TaskForge.Category.Other, REWARD, dl);

        vm.expectRevert(TaskForge.InvalidDescription.selector);
        forge_.createTask(TITLE, "", TaskForge.Category.Other, REWARD, dl);

        vm.expectRevert(TaskForge.InvalidDescription.selector);
        forge_.createTask(TITLE, string(new bytes(2001)), TaskForge.Category.Other, REWARD, dl);

        vm.expectRevert(TaskForge.InvalidReward.selector);
        forge_.createTask(TITLE, DESC, TaskForge.Category.Other, 0, dl);

        vm.expectRevert(TaskForge.InvalidDeadline.selector);
        forge_.createTask(TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp));

        vm.expectRevert(TaskForge.InvalidDeadline.selector);
        forge_.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 366 days)
        );
        vm.stopPrank();
    }

    function test_CreateTask_RejectsFeeOnTransferToken() public {
        FeeToken fee = new FeeToken();
        TaskForge f = new TaskForge(IERC20(address(fee)));
        fee.mint(creator, 1000e6);
        vm.startPrank(creator);
        fee.approve(address(f), type(uint256).max);
        vm.expectRevert(TaskForge.InvalidTransferAmount.selector);
        f.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
    }

    function test_CreateTask_FailedTokenTransfer() public {
        FlakyToken flaky = new FlakyToken();
        TaskForge f = new TaskForge(IERC20(address(flaky)));
        flaky.mint(creator, 1000e6);
        vm.prank(creator);
        flaky.approve(address(f), type(uint256).max);
        flaky.setFail(true);
        vm.prank(creator);
        vm.expectRevert(); // SafeERC20FailedOperation
        f.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
        assertEq(f.taskCount(), 0 + 0); // whole tx reverted; no ghost task
    }

    function test_Constructor_ZeroToken() public {
        vm.expectRevert(TaskForge.ZeroAddress.selector);
        new TaskForge(IERC20(address(0)));
    }

    // ------------------------------------------------------------ submissions

    function test_Submit_Success() public {
        uint256 id = _create();
        vm.expectEmit(true, true, true, true);
        emit SubmissionCreated(id, 0, alice, URL);
        uint256 sid = _submit(alice, id);
        assertEq(sid, 0);
        assertEq(forge_.getTask(id).submissionCount, 1);
        TaskForge.Submission memory s = forge_.getSubmission(sid);
        assertEq(s.contributor, alice);
        assertEq(s.taskId, id);
        (uint256[] memory ids, TaskForge.Submission[] memory subs) =
            forge_.getTaskSubmissions(id, 0, 10);
        assertEq(ids.length, 1);
        assertEq(subs[0].url, URL);
    }

    function test_Submit_Reverts() public {
        uint256 id = _create();

        vm.expectRevert(TaskForge.TaskNotFound.selector);
        vm.prank(alice);
        forge_.submitWork(99, "d", URL);

        vm.expectRevert(TaskForge.CreatorCannotSubmit.selector);
        vm.prank(creator);
        forge_.submitWork(id, "d", URL);

        vm.startPrank(alice);
        vm.expectRevert(TaskForge.InvalidDescription.selector);
        forge_.submitWork(id, "", URL);
        vm.expectRevert(TaskForge.InvalidUrl.selector);
        forge_.submitWork(id, "d", "");
        vm.expectRevert(TaskForge.InvalidUrl.selector);
        forge_.submitWork(id, "d", string(new bytes(301)));
        forge_.submitWork(id, "d", URL);
        vm.expectRevert(TaskForge.AlreadySubmitted.selector);
        forge_.submitWork(id, "d", URL);
        vm.stopPrank();
    }

    function test_Submit_AfterDeadline_Reverts() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(forge_.isExpired(id));
        vm.expectRevert(TaskForge.TaskExpired.selector);
        vm.prank(alice);
        forge_.submitWork(id, "d", URL);
    }

    function test_Submit_AtDeadlineStillAllowed() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 7 days);
        _submit(alice, id);
    }

    // ----------------------------------------------------------------- accept

    function test_Accept_Success() public {
        uint256 id = _create();
        _submit(alice, id);
        uint256 sid = _submit(bob, id);
        vm.expectEmit(true, true, true, false);
        emit SubmissionAccepted(id, sid, bob);
        vm.prank(creator);
        forge_.acceptSubmission(id, sid);

        TaskForge.Task memory t = forge_.getTask(id);
        assertEq(uint8(t.status), uint8(TaskForge.Status.Accepted));
        assertEq(t.contributor, bob);
        assertEq(t.acceptedSubmissionId, sid);
        assertEq(forge_.withdrawableReward(id, bob), REWARD);
        assertEq(forge_.withdrawableReward(id, alice), 0);
    }

    function test_Accept_Unauthorized() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);
        vm.expectRevert(TaskForge.NotCreator.selector);
        vm.prank(alice);
        forge_.acceptSubmission(id, sid);
        vm.expectRevert(TaskForge.NotCreator.selector);
        vm.prank(stranger);
        forge_.acceptSubmission(id, sid);
    }

    function test_Accept_SubmissionFromAnotherTask() public {
        uint256 id0 = _create();
        uint256 id1 = _create();
        _submit(alice, id0); // submission 0 belongs to task 0
        uint256 sid1 = _submit(bob, id1);
        vm.startPrank(creator);
        vm.expectRevert(TaskForge.SubmissionTaskMismatch.selector);
        forge_.acceptSubmission(id1, 0);
        vm.expectRevert(TaskForge.SubmissionTaskMismatch.selector);
        forge_.acceptSubmission(id0, sid1);
        vm.expectRevert(TaskForge.SubmissionNotFound.selector);
        forge_.acceptSubmission(id0, 999);
        vm.stopPrank();
    }

    function test_Accept_Twice_Reverts() public {
        uint256 id = _create();
        uint256 a = _submit(alice, id);
        uint256 b = _submit(bob, id);
        vm.startPrank(creator);
        forge_.acceptSubmission(id, a);
        vm.expectRevert(
            abi.encodeWithSelector(TaskForge.InvalidStatus.selector, TaskForge.Status.Accepted)
        );
        forge_.acceptSubmission(id, b);
        vm.stopPrank();
    }

    function test_Accept_AfterDeadline_Allowed_AndRewardSafe() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);
        vm.warp(block.timestamp + 30 days);
        vm.prank(creator);
        forge_.acceptSubmission(id, sid);
        vm.prank(alice);
        forge_.withdrawReward(id);
        assertEq(usdc.balanceOf(alice), REWARD);
    }

    // --------------------------------------------------------------- withdraw

    function test_Withdraw_Success_AndDoubleWithdrawReverts() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);
        vm.prank(creator);
        forge_.acceptSubmission(id, sid);

        vm.expectEmit(true, true, false, true);
        emit RewardWithdrawn(id, alice, REWARD);
        vm.prank(alice);
        forge_.withdrawReward(id);

        assertEq(usdc.balanceOf(alice), REWARD);
        assertEq(usdc.balanceOf(address(forge_)), 0);
        assertEq(forge_.totalEscrowed(), 0);
        assertEq(uint8(forge_.getTask(id).status), uint8(TaskForge.Status.Completed));

        vm.expectRevert(
            abi.encodeWithSelector(TaskForge.InvalidStatus.selector, TaskForge.Status.Completed)
        );
        vm.prank(alice);
        forge_.withdrawReward(id);
    }

    function test_Withdraw_Unauthorized() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);
        vm.prank(creator);
        forge_.acceptSubmission(id, sid);
        vm.expectRevert(TaskForge.NotContributor.selector);
        vm.prank(bob);
        forge_.withdrawReward(id);
        vm.expectRevert(TaskForge.NotContributor.selector);
        vm.prank(creator);
        forge_.withdrawReward(id);
    }

    function test_Withdraw_BeforeAcceptance_Reverts() public {
        uint256 id = _create();
        _submit(alice, id);
        vm.expectRevert(
            abi.encodeWithSelector(TaskForge.InvalidStatus.selector, TaskForge.Status.Open)
        );
        vm.prank(alice);
        forge_.withdrawReward(id);
    }

    function test_Withdraw_FailedTokenTransfer_RevertsAndKeepsState() public {
        FlakyToken flaky = new FlakyToken();
        TaskForge f = new TaskForge(IERC20(address(flaky)));
        flaky.mint(creator, 1000e6);
        vm.prank(creator);
        flaky.approve(address(f), type(uint256).max);
        vm.prank(creator);
        uint256 id = f.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
        vm.prank(alice);
        uint256 sid = f.submitWork(id, "d", URL);
        vm.prank(creator);
        f.acceptSubmission(id, sid);

        flaky.setFail(true);
        vm.prank(alice);
        vm.expectRevert();
        f.withdrawReward(id);
        // state rolled back: reward still withdrawable once token recovers
        assertEq(f.withdrawableReward(id, alice), REWARD);
        assertEq(f.totalEscrowed(), REWARD);

        flaky.setFail(false);
        vm.prank(alice);
        f.withdrawReward(id);
        assertEq(flaky.balanceOf(alice), REWARD);
    }

    // ----------------------------------------------------------------- cancel

    function test_Cancel_NoSubmissions_RefundsCreator() public {
        uint256 before_ = usdc.balanceOf(creator);
        uint256 id = _create();
        assertTrue(forge_.canCancel(id));
        vm.expectEmit(true, true, false, true);
        emit TaskCancelled(id, creator, REWARD);
        vm.prank(creator);
        forge_.cancelTask(id);
        assertEq(usdc.balanceOf(creator), before_);
        assertEq(forge_.totalEscrowed(), 0);
        assertEq(uint8(forge_.getTask(id).status), uint8(TaskForge.Status.Cancelled));
    }

    function test_Cancel_Unauthorized() public {
        uint256 id = _create();
        vm.expectRevert(TaskForge.NotCreator.selector);
        vm.prank(stranger);
        forge_.cancelTask(id);
    }

    function test_Cancel_Twice_Reverts() public {
        uint256 id = _create();
        vm.startPrank(creator);
        forge_.cancelTask(id);
        vm.expectRevert(
            abi.encodeWithSelector(TaskForge.InvalidStatus.selector, TaskForge.Status.Cancelled)
        );
        forge_.cancelTask(id);
        vm.stopPrank();
    }

    function test_Cancel_WithSubmissions_BlockedUntilReviewPeriodEnds() public {
        uint256 id = _create();
        _submit(alice, id);
        assertFalse(forge_.canCancel(id));
        vm.expectRevert(TaskForge.CancelNotAllowed.selector);
        vm.prank(creator);
        forge_.cancelTask(id);

        // deadline passed but review period not over
        vm.warp(block.timestamp + 7 days + 7 days);
        vm.expectRevert(TaskForge.CancelNotAllowed.selector);
        vm.prank(creator);
        forge_.cancelTask(id);

        vm.warp(block.timestamp + 1);
        assertTrue(forge_.canCancel(id));
        vm.prank(creator);
        forge_.cancelTask(id);
        assertEq(usdc.balanceOf(address(forge_)), 0);
    }

    function test_Cancel_Expired_NoSubmissions() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 8 days);
        assertTrue(forge_.isExpired(id));
        vm.prank(creator);
        forge_.cancelTask(id);
        assertFalse(forge_.isExpired(id)); // Cancelled, no longer "open & expired"
    }

    function test_Cancel_AfterAcceptance_Reverts_ContributorProtected() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);
        vm.prank(creator);
        forge_.acceptSubmission(id, sid);
        vm.warp(block.timestamp + 365 days);
        assertFalse(forge_.canCancel(id));
        vm.expectRevert(
            abi.encodeWithSelector(TaskForge.InvalidStatus.selector, TaskForge.Status.Accepted)
        );
        vm.prank(creator);
        forge_.cancelTask(id);
        vm.prank(alice);
        forge_.withdrawReward(id);
        assertEq(usdc.balanceOf(alice), REWARD);
    }

    function test_Cancel_AfterCompleted_Reverts() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);
        vm.prank(creator);
        forge_.acceptSubmission(id, sid);
        vm.prank(alice);
        forge_.withdrawReward(id);
        vm.expectRevert(
            abi.encodeWithSelector(TaskForge.InvalidStatus.selector, TaskForge.Status.Completed)
        );
        vm.prank(creator);
        forge_.cancelTask(id);
    }

    function test_Cancel_Then_Accept_Reverts() public {
        uint256 id = _create();
        vm.prank(creator);
        forge_.cancelTask(id);
        vm.expectRevert(TaskForge.TaskNotFound.selector);
        vm.prank(creator);
        forge_.acceptSubmission(7, 0);
    }

    // ------------------------------------------------------------- reentrancy

    function _reentrantSetup()
        internal
        returns (ReentrantToken rt, TaskForge f, uint256 id, uint256 sid)
    {
        rt = new ReentrantToken();
        f = new TaskForge(IERC20(address(rt)));
        rt.mint(creator, 1000e6);
        vm.startPrank(creator);
        rt.approve(address(f), type(uint256).max);
        // two tasks so reentry has other funds to try to steal
        f.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
        id = f.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
        vm.prank(alice);
        sid = f.submitWork(id, "d", URL);
        vm.prank(creator);
        f.acceptSubmission(id, sid);
    }

    function test_Reentrancy_WithdrawCannotDoubleSpend() public {
        (ReentrantToken rt, TaskForge f, uint256 id,) = _reentrantSetup();
        // On the outgoing transfer, the token calls withdrawReward again (msg.sender = token).
        rt.arm(address(f), abi.encodeCall(TaskForge.withdrawReward, (id)));
        vm.prank(alice);
        f.withdrawReward(id);
        assertTrue(rt.reentryReverted());
        assertEq(rt.balanceOf(alice), REWARD);
        assertEq(rt.balanceOf(address(f)), REWARD); // other task's escrow untouched
        assertEq(f.totalEscrowed(), REWARD);
    }

    function test_Reentrancy_CancelCannotReenter() public {
        ReentrantToken rt = new ReentrantToken();
        TaskForge f = new TaskForge(IERC20(address(rt)));
        rt.mint(creator, 1000e6);
        vm.startPrank(creator);
        rt.approve(address(f), type(uint256).max);
        uint256 a = f.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
        f.createTask(
            TITLE, DESC, TaskForge.Category.Other, REWARD, uint64(block.timestamp + 1 days)
        );
        vm.stopPrank();
        rt.arm(address(f), abi.encodeCall(TaskForge.cancelTask, (a)));
        vm.prank(creator);
        f.cancelTask(a);
        assertTrue(rt.reentryReverted());
        assertEq(rt.balanceOf(address(f)), REWARD);
        assertEq(f.totalEscrowed(), REWARD);
    }

    // ------------------------------------------------------------- accounting

    function test_Accounting_MultipleTasks() public {
        uint256 t0 = _create();
        uint256 t1 = _create();
        uint256 t2 = _create();
        assertEq(forge_.totalEscrowed(), 3 * REWARD);
        assertEq(usdc.balanceOf(address(forge_)), 3 * REWARD);

        uint256 s0 = _submit(alice, t0);
        uint256 s1 = _submit(bob, t1);
        vm.startPrank(creator);
        forge_.acceptSubmission(t0, s0);
        forge_.acceptSubmission(t1, s1);
        forge_.cancelTask(t2); // refund must not touch t0/t1 escrow
        vm.stopPrank();

        assertEq(forge_.totalEscrowed(), 2 * REWARD);
        assertEq(usdc.balanceOf(address(forge_)), 2 * REWARD);

        vm.prank(alice);
        forge_.withdrawReward(t0);
        assertEq(forge_.totalEscrowed(), REWARD);
        assertEq(usdc.balanceOf(address(forge_)), REWARD);

        vm.prank(bob);
        forge_.withdrawReward(t1);
        assertEq(forge_.totalEscrowed(), 0);
        assertEq(usdc.balanceOf(address(forge_)), 0);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), 2 * REWARD);
        assertEq(usdc.balanceOf(creator), 10_000e6 - 2 * REWARD);
    }

    function test_Pagination() public {
        for (uint256 i; i < 5; ++i) {
            _create();
        }
        assertEq(forge_.getTasks(0, 3).length, 3);
        assertEq(forge_.getTasks(3, 10).length, 2);
        assertEq(forge_.getTasks(5, 10).length, 0);
        (uint256[] memory ids,) = forge_.getTaskSubmissions(0, 0, 10);
        assertEq(ids.length, 0);
        vm.expectRevert(TaskForge.TaskNotFound.selector);
        forge_.getTask(5);
    }

    // ---------------------------------------------------------------- fuzzing

    /// @dev Invariant-style check: contract token balance always covers totalEscrowed.
    function testFuzz_EscrowAlwaysCovered(uint96 r1, uint96 r2, bool cancelFirst) public {
        r1 = uint96(bound(r1, 1, 1000e6));
        r2 = uint96(bound(r2, 1, 1000e6));
        uint64 dl = uint64(block.timestamp + 1 days);
        vm.startPrank(creator);
        uint256 a = forge_.createTask(TITLE, DESC, TaskForge.Category.Other, r1, dl);
        uint256 b = forge_.createTask(TITLE, DESC, TaskForge.Category.Other, r2, dl);
        if (cancelFirst) forge_.cancelTask(a);
        vm.stopPrank();
        uint256 sid = _submit(alice, b);
        vm.prank(creator);
        forge_.acceptSubmission(b, sid);
        assertGe(usdc.balanceOf(address(forge_)), forge_.totalEscrowed());
        vm.prank(alice);
        forge_.withdrawReward(b);
        assertGe(usdc.balanceOf(address(forge_)), forge_.totalEscrowed());
        assertEq(usdc.balanceOf(alice), r2);
    }

    function test_RejectSubmission_StoresReasonAndLeavesTaskOpen() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);

        string memory reason =
            "This submission does not meet the task requirements because key requested functionality is missing and tests are not included.";

        vm.prank(creator);
        forge_.rejectSubmission(id, sid, reason);

        assertTrue(forge_.submissionRejected(sid));
        assertEq(forge_.submissionRejectionReason(sid), reason);
    }

    function test_RejectSubmission_RequiresAtLeast15Words() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);

        vm.expectRevert(TaskForge.RejectionReasonTooShort.selector);
        vm.prank(creator);
        forge_.rejectSubmission(
            id,
            sid,
            "This reason has only seven words total"
        );
    }

    function test_RejectSubmission_Unauthorized() public {
        uint256 id = _create();
        uint256 sid = _submit(alice, id);

        string memory reason =
            "This submission misses the required deliverable and does not demonstrate that the requested task has been completed.";

        vm.expectRevert(TaskForge.NotCreator.selector);
        vm.prank(alice);
        forge_.rejectSubmission(id, sid, reason);
    }

}
