# Homework 5

#### _“Solidity, typical patterns”_

Simple voting contract based on ERC20Snapshot. Token holders can create proposals and for/against it.
New snapshot is created for each proposal to keep track of voters balances.

Events are emitted on proposal creation, accept, decline and discard. No events are emitted when user votes.
Withdraw vote or revote is not possible.

Proposal is simply `uint64` hash stored with additional info:
```solidity
struct Proposal {
        /// @dev Votes "for" this proposal
        uint64 votesFor;

        /// @dev Votes "against" this proposal
        uint64 votesAgainst;

        /// @dev When this proposal was created.
        uint64 createdTimestamp;

        /// @dev Snapshot to use to get users balances.
        /// New snapshot is created for each proposal.
        uint64 snapshotId;

        /// @dev Whether this address have voted or not
        mapping(address => bool) voted;
    }
```

Hashes are stored in queue `_proposalsQueue`, ordered by their timestamps.
`Proposal` structs are stored in `mapping(uint64 => Proposal) proposals`.


### How to run tests

``` bash
npm install
npx hardhat test
```


### Tests log example

```
  Vote
    Deployment
      ✔ Should set the right total supply
      ✔ Should mint tokens to owner
    Events
      ✔ Should emit event on create
      ✔ Should emit event on accept
      ✔ Should emit event on reject
      ✔ Should emit event on discard
    Basic reverts
      ✔ Should not create zero-hash proposal
      ✔ Should not vote for/against zero-hash proposal
      ✔ Should not vote for non existing proposal
      ✔ Should not create proposal with zero balance
      ✔ Should not vote with zero balance
      ✔ Should not create same proposal twice
      ✔ Should not create too many proposals (47ms)
    Snapshots
      ✔ Should use balance from correct snapshot (107ms)
    Queue
      ✔ Should discard most obsolete proposals on creation (102ms)
    Stress test
Gas used:  31781316
      ✔ Calculate gas (5045ms)


  16 passing (7s)

```