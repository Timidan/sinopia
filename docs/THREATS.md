# Sinopia threat model

## Trust roots

- The constructor receives immutable IMD and Intake addresses. It makes no external calls. A wrong address makes the deployment unusable; there is no admin to replace it.
- Intake is the only accepted callback sender. Its owner and writer are single EOAs; the writer forwards callback arguments as-is, and the owner can set `callbackGas` (200,000 today). It may withhold a result or report failure, but the winner's remaining escrow can only go to that winner or be burned after a hash-checked valid image result. A false failure does not move value in the callback; it opens the refund path. The paid 0.5 IMD cannot be recovered. The first image-job callback on chain 4663 is unobserved.
- An Intake result hash authenticates the JSON supplied to `reveal` or `rejectDelivery`. The parser reads root completion markers and image file fields structurally. Only a well-formed result without an image or without completed markers is rejectable; unparseable results expire after seven days and then the winner can claim a refund. The contract checks format and image hash, not the visual content or the swarm's performance.
- Metadata points to `api.imd.fun/artifacts/<sha256>`. Availability depends on IMD hosting. A collector can verify downloaded PNG bytes against the stored SHA-256 hash.
- If the Intake price or version changes and settlement reverts, the round remains Open and `cancelUnsettled` releases the full bid after its grace period.
- Briefs are restricted to a small ASCII charset and 8–200 bytes. This protects onchain JSON syntax and metadata. It cannot prevent semantic prompt injection or guarantee a satisfactory image.
- The IMD token owner (the same key as Intake owner) can block addresses and gate transfers, freezing payouts.
- Accepted trade-off: a winner can void their own round with a brief IMD refuses, costing them the 0.5 IMD job fee; outbid bidders were refunded in full and the next round opens at once. Burning on refusal would also punish honest winners if IMD's screen is stricter than its free pre-check. Post-payment refusals cost the winner 0.5 IMD.
- A keeper outside the contract settles ended rounds and reveals delivered ones.
- No owner, privileged role, upgrade, pause, seizure, or arbitrary withdrawal exists. Accidental IMD transfers remain in the contract.

## Value movement

| Function | Source | Destination | Condition |
|---|---|---|---|
| `bid` | bidder | Sinopia escrow | Exact IMD amount received |
| `bid` | escrow | previous top bidder or their credit | Full previous bid when outbid |
| `settle` | escrow | Intake | Exactly 0.5 IMD for one job |
| `reveal` | escrow | burn address | Winning bid minus job charge, after result hash and image checks |
| `claimRefund` | escrow | winner or their credit | Winning bid minus job charge after Failed or Expired |
| `cancelUnsettled` | escrow | winner or their credit | Full bid after grace period with no settlement |
| `claim` | pending credit | credited account | Caller can withdraw only their own credit |

`onResult`, `onFailure`, `rejectDelivery`, and `expire` move no IMD. All value-moving functions use checks, state updates, and a reentrancy guard; failed pushes become credits. `escrowed` tracks obligations independently of `balanceOf(this)`.
