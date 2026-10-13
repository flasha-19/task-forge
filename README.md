# Task Forge

### An Onchain Task Marketplace Powered by Arc and USDC

Task Forge is a decentralized task marketplace built on **Arc**, designed to connect people who need work done with contributors who want to earn rewards.

Anyone can create a task, fund it with USDC, submit work, and receive payment through smart contracts.

From fixing GitHub issues and building software features to developing smart contracts, writing documentation, and creating developer tools, Task Forge makes it possible to coordinate digital work with transparent, onchain payments.

**Build something. Complete tasks. Earn USDC.**

---

## Overview

Traditional freelance platforms often rely on centralized payment systems, platform fees, and intermediaries.

Task Forge explores an alternative: a task marketplace where smart contracts manage reward funding, enforce payment rules, and make task-related transactions publicly verifiable.

The project uses Arc's EVM-compatible environment and USDC-based transactions to demonstrate how onchain infrastructure can support practical applications for developers and independent contributors.

### Key Features

* **Open Task Marketplace:** Create and discover tasks across multiple categories.
* **USDC Rewards:** Fund tasks with USDC and pay contributors for accepted work.
* **Onchain Escrow:** Lock task rewards in smart contracts until the applicable payment conditions are met.
* **Transparent Payments:** Inspect transactions and contract activity on the Arc Testnet explorer.
* **GitHub-Friendly Workflows:** Submit GitHub issues, pull requests, repositories, and other deliverable links.
* **Wallet Integration:** Interact with the application through a compatible EVM wallet.
* **Smart Contract Security:** Test authorization, payment accounting, withdrawal logic, and task state transitions.
* **Open Source:** Provide a foundation for developers to extend and improve the marketplace.

> **Project status:** Experimental MVP targeting Arc Testnet. Features, deployment status, and security guarantees depend on the current implementation. This project is not presented as an audited production protocol.

---

## How It Works

### 1. Create a Task

A task creator publishes a task with a title, description, category, reward, deadline, and acceptance criteria.

Examples include:

* Fix a bug in an open-source repository.
* Implement a new application feature.
* Develop a Solidity smart contract.
* Build a frontend interface.
* Write technical documentation.
* Create a developer tool or automation script.

### 2. Fund the Task

The creator deposits the specified USDC reward into the task's smart contract.

The contract records the task and its funded reward.

### 3. Complete the Work

Contributors browse available tasks, select suitable work, and submit their deliverables.

Submissions can reference GitHub pull requests, repositories, documentation, or other relevant resources.

### 4. Review the Submission

The task creator reviews the submitted work and decides whether it satisfies the task's acceptance criteria.

Task Forge does not assume that a URL or submission automatically proves that work is correct.

### 5. Receive the Reward

Once a submission is accepted, the smart contract establishes the contributor's reward entitlement.

The contributor can then withdraw the eligible reward according to the contract's payment rules.

**Important:** The actual behavior depends on the implemented contract and its task lifecycle. Cancellation, expiration, and refund rules must preserve any reward entitlement that has already been established.

---

## Why Arc?

Task Forge is built for Arc, an EVM-compatible blockchain designed around stablecoin-based financial applications.

Arc provides an environment for exploring smart contracts, USDC payments, and blockchain-based application development.

By building Task Forge on Arc, the project demonstrates how programmable financial infrastructure can support task coordination and transparent reward distribution.

### Arc Testnet Resources

* [Arc Official Website](https://www.arc.io/)
* [Arc Documentation](https://docs.arc.network/)
* [Arc Testnet Explorer](https://testnet.arcscan.app/)
* [Arc Testnet RPC](https://rpc.testnet.arc.network)
* [Circle Faucet](https://faucet.circle.com/)

Verify the current network configuration and official testnet token addresses against the latest documentation before interacting with the application.

---

## Arc Testnet Configuration

The initial target configuration is:

| Setting  | Value                             |
| -------- | --------------------------------- |
| Network  | Arc Testnet                       |
| Chain ID | `5042002`                         |
| RPC URL  | `https://rpc.testnet.arc.network` |
| Explorer | `https://testnet.arcscan.app/`    |
| Faucet   | `https://faucet.circle.com/`      |

Confirm these values against the current official Arc documentation before deployment.

### USDC Integration

Task Forge uses the verified Arc Testnet ERC-20 USDC contract for task funding and reward payments.

Do not assume that the native token used for gas is interchangeable with the ERC-20 contract used by the escrow.

The token address and decimals must be verified before deployment.

**Do not deploy the contracts with an unverified token address.**

---

## Testing and Auditing

The project should include Foundry tests for expected behavior and adversarial cases.

Passing tests does not prove that a contract is free of vulnerabilities.

Unless an independent audit has actually been completed and documented, Task Forge must not be represented as audited.

Use testnet funds only.

### Responsible Disclosure

If you discover a security issue, avoid publicly disclosing exploitable details before the issue has been investigated and addressed.

Report issues through the repository's GitHub Issues or another disclosure channel designated by the maintainers.

Do not include private keys, credentials, or sensitive personal information in issue reports.

---

## Acknowledgments

Task Forge is built to explore the possibilities of Arc, Solidity, and programmable USDC payments.

The project aims to make it easier to connect useful digital work with transparent, verifiable onchain rewards.

**Task Forge — Build. Contribute. Earn.**
