# About

Implementation of a SuperApp based referral system.  
Incoming streams can be split up into several outgoing streams, according to the config set in the contract.  
The remaineder stream is forwarded to the merchant, such that the contract never holds any funds (other than dust due to rounding artifacts).

On contract creation, a supported SuperToken, a _merchant_, a _referral fee table_, a _protocol fee recipient_ and a _protocol fee_ are specified.

## (Normal) referrers

The primary way to specify referers is most flexible, as it allows individual stream opening transactions to designate arbitrate addresses as referrer.  
When streaming to this SuperApp, a _referrer_ address can be specified in [userData](https://docs.superfluid.finance/superfluid/developers/super-apps/user-data).
If a referrer is defined, a share (defined by the referral fee table) of the incoming stream is forwarded to the referrer.  

The referrer is also persisted by the contract in order to allow for multi-level referrals.

The _referral fee table_ allows to have a multi-level referral system and is implemented as a simple array of ints.  
The first array item specifies the share for the first level (direct) referrer in parts per million.  
The second item specifies the share for the second level (indirect) referrer in parts per million.  
Etc...  
In theory an arbitrary number of levels could be supported, but due to the block size limit, that's not possible in practice. Up to 10 levels is safe though.  

## Special referrers

A _special referrer_ is an entity specified in the referral contract by the owner with the method `setSpecialReferrer()`.  
It can be used to reward referring platforms, wallets, etc.  

In order to keep calldata small, a _cAddr_ (compressed address) is created for every special referrer set in the contract.  
The cAddr is returned by `setSpecialReferrer`, which also emits an event `SpecialReferrerSet` with `cAddr` as one of its arguments.  
This cAddr can be used for identifying the special referrers in stream opening calls.

In order to reward special refererrs, the userData needs to be encoded differently:
Instead of encoding just a referrer address, you can additionally encode up to 2 special referrers, like this:
```solidity
address referrerAddr = ...; // the "normal" / organic referrer
uint32 specialReferrer1Id = ...; // cAddr of first special referrer
uint32 specialReferrer2Id = ...; // cAddr of second special referrer. Set to 0 if none to be set.
bytes4 reseved = bytes4(0); // has no effect, reserved for future use. But must be set for correct memory layout.
bytes memory userData = abi.encodePacked(reserved, specialReferrer2Id, specialReferrer1Id, referrerAddr);
```
**Important:** you MUST use `abi.encodePacked` for this to work. If the data is not packed, it won't work as expected.

## Protocol fee

If specified on contract creation, a protocol fee will also be taken from incoming streams.

# Develop

Prerequisite: [foundry](https://book.getfoundry.sh/) installed, `forge` in PATH.

In order to install, clone the repository, then run `forge install`.
Run tests with `forge test`

## DEVX notes

SuperTokenV1Library should have a helper method for initializing the cache, in order to avoid the issue with reverts not being recognized due to the preceding low level call (see https://github.com/foundry-rs/foundry/issues/3901https://github.com/superfluid-finance/protocol-monorepo/issues/1697)

SuperTokenV1Library should have a `setFlowRate` (semantics: create or update or delete flow, depending on previous state and new flowrate)

SuperAppBaseFlow should be renamed to CFASuperAppBase and include helpers for dealing with clipping. E.g. something like `getMaxAdditionalFlowRate(ctx)` which calculates based on the appCredit situation in ctx.

SuperAppBaseFlow expects the deployer to be an EOA, won't work with a factory contract being the deployer.
Fixing this may be simplified by https://github.com/superfluid-finance/protocol-monorepo/issues/1660

# TODO

* implement `onFlowDeleted`
* (maybe) implement `onFlowUpdated`
* (maybe) implement option to change the fee table (consider all possible implications before doing so)
* Implement a factory which allows us to build a Dapp for merchants to easily deploy instances