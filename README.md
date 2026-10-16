# Sinopia

Sinopia is an onchain auction where each winning bid commissions the IMD swarm to paint the winner's brief, and the finished fresco is minted to the winner.

Bid at least 0.55 IMD with your idea. When the round ends, the highest bid wins. The contract pays the IMD swarm 0.5 IMD to paint the winning idea as a fresco and burns the rest of the winning bid. The painting is minted to the winner as an NFT. Outbid? Your IMD comes straight back. If the swarm can't paint it, the winner gets back everything except the 0.5 IMD the swarm charged.

## Contract

`Sinopia` is an ERC-721 named Sinopia (`SINOPIA`) on Robinhood Chain. Call `bid(roundId, amount, brief)` for the current open round or the next round if the previous one ended. Rounds last three hours; a bid in the last five minutes moves the end to five minutes from now. An ended round can be settled while new bidding opens a new round. Each bid escrows its exact IMD amount. Outbid bidders receive an immediate refund, or a claimable credit if the token transfer fails. There is no owner, admin, pause, arbitrary withdrawal, or owner mint.

Settlement buys one `job.open@job-1` image job through IMD Intake v2 for exactly 0.5 IMD. The contract records the Intake result hash. Anyone can reveal the canonical result JSON after a hash match; a valid image result mints exactly one NFT, token ID equal to the round ID, to the winning bidder and burns the remaining bid. This reveal is the only NFT mint path. The token URI is onchain JSON containing the brief, job link, result hash, and the PNG's SHA-256 hash. The image bytes are hosted by `api.imd.fun`.

An Intake failure or a delivery missing a completed image lets anyone release the winner's bid minus the 0.5 IMD already paid. A commissioned job without delivery expires after three days; an unrevealed delivery, including one with another malformed field, expires after seven days. An uncommissioned ended round can be cancelled after one day for a full refund. Accidental IMD transfers are not included in escrow and cannot be withdrawn.

## Trust and limits

The immutable Intake and IMD addresses must be correct at deployment. Intake controls delivery and failure callbacks; the delivered bytes are authenticated by their onchain hash, but the contract does not independently verify the image's artistic quality or the IMD swarm's work. The PNG URL depends on IMD hosting, while the SHA-256 hash lets a collector check downloaded bytes. The job charge is nonrefundable after settlement. A winner can void their own round with a brief IMD refuses, costing them the 0.5 IMD job fee; outbid bidders were refunded in full and the next round opens at once. See [THREATS.md](docs/THREATS.md) and [LAUNCH.md](docs/LAUNCH.md).

## Build and test

Dependencies are vendored as plain files in `lib/`: forge-std v1.14.0 and OpenZeppelin Contracts v5.4.0. No network is needed for the default tests.

```sh
forge fmt --check
forge build --sizes
forge test
FOUNDRY_PROFILE=fork forge test
```

The fork profile uses `https://rpc.mainnet.chain.robinhood.com` and runs the offline suite plus a live Intake payment test. It changes only forked state and does not broadcast a transaction. The default profile excludes `test/fork/*` by path.
