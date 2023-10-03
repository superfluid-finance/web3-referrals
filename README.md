# About

SuperApp based referral system.
On contract creation, a supported SuperToken, a _merchant_ and a _referral fee table_ are specified.

When streaming to this SuperApp, a _referrer_ address can be specified in [userData](https://docs.superfluid.finance/superfluid/developers/super-apps/user-data).
If a referrer is defined, a share (defined by the referral fee table) of the incoming stream is forwarded to the referrer, the rest to the merchant.
The referrer is also persisted by the contract in order to allow for multi-level referrals.

The referral fee table is implemented as a simple array of ints.  
The first array item specifies the share for the first level (direct) referrer in parts per million.
The second item specifies the share for the second level (direct) referrer in parts per million.
Etc.
In theory an arbitrary number of levels could be supported, but due to the block size limit, that's not possible in practice. Up to 10 levels is safe though.
The sum of shares for all levels cannot exceed 100% / 1e PPM.

# Develop

Prerequisite: [foundry](https://book.getfoundry.sh/) installed, `forge` in PATH.

In order to install, clone the repository, then run `forge install`.
Run tests with `forge test`

## Special referrers

A _special referrer_ is an entity specied in the referral contract by the owner with the method `setSpecialReferrer()`.  
This returns a _shortId_ to be used for identifying the special referrers in stream opening calls.
The shortId is returned by `setSpecialReferrer`, which also emits an event `SpecialReferrerSet` with `shortId` as one of its arguments.

In order to reward special refererrs, the userData needs to be encoded differently:
Instead of encoding just a referrer address, you can additional encode up to 2 special referrers, like this:
```solidity
address referrerAddr = ...; // the "normal" / organic referrer
uint32 specialReferrer1Id = ...; // shortId of first special referrer
uint32 specialReferrer2Id = ...; // shortId of second special referrer. Set to 0 if none to be set.
bytes4 reseved = bytes4(0); // has no effect, reserved for future use. But must be set for correct memory layout.
bytes memory userData = abi.encodePacked(reserved, specialReferrer2Id, specialReferrer1Id, referrerAddr);
```
**Important:** you MUST use `abi.encodePacked` for this to work. If the data is not packed, it won't work as expected.

## DEVX notes

SuperTokenV1Library should have a helper method for initializing the cache, in order to avoid the issue with reverts not being recognized due to the preceding low level call (see https://github.com/foundry-rs/foundry/issues/3901https://github.com/superfluid-finance/protocol-monorepo/issues/1697)

SuperTokenV1Library should have a `setFlowRate` (semantics: create or update or delete flow, depending on previous state and new flowrate)

SuperAppBaseFlow should be renamed to CFASuperAppBase and include helpers for dealing with clipping. E.g. something like `getMaxAdditionalFlowRate(ctx)` which calculates based on the appCredit situation in ctx.

SuperAppBaseFlow expects the deployer to be an EOA, won't work with a factory contract being the deployer.
Fixing this may be simplified by https://github.com/superfluid-finance/protocol-monorepo/issues/1660