# Security

## Status
Task Forge is an **unaudited testnet MVP**. Do not use it with real funds.

## Reporting a vulnerability
Please open a private security advisory on this repository (Security → Report a vulnerability), or contact the maintainers privately. Do not file public issues for exploitable bugs.

## Design notes
- Pull-payment rewards; state is updated before token transfers (checks-effects-interactions) and value-moving functions use `nonReentrant`.
- `SafeERC20` for all transfers; fee-on-transfer tokens rejected at funding time.
- Accepted rewards cannot be cancelled or refunded away; refunds only return that task's own escrow.
- Inputs are validated onchain (lengths, reward, deadline window); frontend validation is only UX.
- No upgradeability, no admin, no owner-controlled funds.

## Trust assumptions
- The USDC token behaves like a standard ERC-20 (can still blacklist/pause addresses, which can block a withdrawal for that address).
- The creator alone decides which submission wins.
- Submission descriptions and URLs are user-supplied text; the UI only renders http(s) links and treats everything as plain text.

## Secrets
Never commit `.env` or private keys. Frontend `VITE_*` variables are public. Use a throwaway key for testnet deployment.
