# Launch preparation

Sinopia is an onchain auction where each winning bid commissions the IMD swarm to paint the winner's brief, and the finished fresco is minted to the winner.

The target is an `evm_contracts` launch on Robinhood Chain (4663): one `Sinopia` contract, no launch token or pool. No launch manifest belongs in this source tree. IMD's manifest step creates `launch.json` after the build is accepted.

## Free gate before the single paid launch

After the user approves a public push, use the resulting repository URL and base commit:

1. `POST https://api.imd.fun/requests/import` with `{"url":"<public repo URL>","ref":"<base commit>","kind":"contracts"}`.
2. `POST https://api.imd.fun/requests/check` with `{"action":"launch.open","input":{"objective":"Sinopia: an onchain auction on Robinhood Chain (4663) where each winning bid commissions the IMD swarm, through Intake v2, to paint the winner's brief; the finished fresco is minted to the winner. Deploy the Sinopia contract from this repository as it arrived: evm_contracts, no token, no pool, constructor args in order (Intake v2 0xa43e6f75ee006411f79ac1c84120606c2330de82, then IMD 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127). Do not edit src/ unless an audit finding reproduces. The ERC-721 mint in reveal() is the product, not post-launch supply minting: it creates exactly one NFT per settled and delivered commission (token id = round id), only to that round's winning bidder, only after the Intake-delivered result hash matches; there is no owner, admin or other mint path. IMD has deployed the same NFT pattern: launch #1756 VeteransNFT.mint → _safeMint and launch #1716 KeelNotes.mint → _mint. Tests: offline suite plus a Robinhood fork test against the live Intake (README.md, docs/THREATS.md).","repoUrl":"<public repo URL>","baseCommit":"<base commit>","onchain":"evm_contracts","chainId":4663,"contracts":["Sinopia"]}}`.
3. Pay only if `blockers` is empty and the returned `plan` includes audit-imported-code, adapt, audit panel, and deploy in that order.

The paid launch is sent from the user's own wallet. That payer is the only identity on an `evm_contracts` launch record; Radar shows IMD's factory as deployer. Do not use an agent wallet or broadcast during preparation.

Expected manifest content, written only by IMD's manifest step:

```json
{"kind":"evm_contracts","contracts":[{"contract":"Sinopia","constructorArgs":["0xa43e6f75ee006411f79ac1c84120606c2330de82","0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127"]}],"notes":"Deploy as it arrived; do not edit src/ unless an audit finding reproduces."}
```

Launch request text (paste into explorer.imd.fun/launch → Contracts → Start from GitHub → "What do the contracts do, and what should launch?"):

> Sinopia: an onchain auction on Robinhood Chain (4663) where each winning bid commissions the IMD swarm, through Intake v2, to paint the winner's brief; the finished fresco is minted to the winner. Deploy the Sinopia contract from this repository as it arrived: evm_contracts, no token, no pool, constructor args in order (Intake v2 0xa43e6f75ee006411f79ac1c84120606c2330de82, then IMD 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127). Do not edit src/ unless an audit finding reproduces. The ERC-721 mint in reveal() is the product, not post-launch supply minting: it creates exactly one NFT per settled and delivered commission (token id = round id), only to that round's winning bidder, only after the Intake-delivered result hash matches; there is no owner, admin or other mint path. IMD has deployed the same NFT pattern: launch #1756 VeteransNFT.mint → _safeMint and launch #1716 KeelNotes.mint → _mint. Tests: offline suite plus a Robinhood fork test against the live Intake (README.md, docs/THREATS.md).

Before payment, review the constructor arguments, public source commit, free check response, and the fact that NFT minting happens only on a verified post-delivery reveal. IMD's import audit lists "minting after launch" as forbidden; it targets token supply, and many NFT launches on IMD mint after deployment. The request text above, the NatSpec on reveal() and the README state that the reveal mint is the product, so the adapter keeps it. The audit runs only after payment, so this text is the protection.

## Post-deploy checks

1. Read `intake()` and `imd()` from the deployed Sinopia and compare them to the ordered constructor addresses above.
2. Compare its runtime `extcodehash` to the build artifact.
3. Run one smoke read of `latestRoundId()`.
