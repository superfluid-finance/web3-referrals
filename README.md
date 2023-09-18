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
Run tests with `forge test -vvv`