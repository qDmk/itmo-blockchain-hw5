pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

uint8 constant DECIMALS = 6;
uint8 constant TOTAL_SUPPLY = 100;         // Total token supply. Raw value, without decimal part
uint8 constant REQUIRED_FOR_DECISION = 50; //
uint32 constant PROPOSAL_TTL = 3 days;
uint16 constant MAX_PROPOSALS = 3;         // Maximal amount of proposals at the same time

struct Proposal {
    uint hash;                      // Proposal hash that users vote for
    uint128 votesFor;               // Votes "for" this proposal
    uint128 votesAgainst;           // Votes "against" this proposal
    mapping(address => bool) voted; // Whether this address have voted or not
    uint timestamp;                 // When this proposal was created.
    uint snapshotId;                // Snapshot to use to get users balances.
                                    // New snapshot is created for each proposal.
}

library ArrayQueue {
    uint16 constant MAX_SIZE = MAX_PROPOSALS;

    struct Queue {
        uint[MAX_SIZE] _data;
        uint32 _begin;
        uint32 _size;
    }

    function empty(Queue storage queue) public view returns (bool) {
        return queue._size == 0;
    }

    function size(Queue storage queue) public view returns (uint32) {
        return queue._size;
    }

    function first(Queue storage queue) public view returns (uint) {
        require(size(queue) > 0, "Queue is empty");

        return queue._data[queue._begin];
    }

    function add(Queue storage queue, uint elem) public {
        require(size(queue) < MAX_SIZE, "Queue is full");

        queue._data[(queue._begin + queue._size) % MAX_SIZE] = elem;
        queue._size++;
    }

    function find(Queue storage queue, uint elem) private view returns (uint32) {
        uint32 end = (queue._begin + queue._size) % MAX_SIZE;
        for (uint32 i = queue._begin; i != end; i = (i + 1) % MAX_SIZE) {
            if (queue._data[i] == elem) {
                return i;
            }
        }

        revert("Element not found");
    }

    function remove(Queue storage queue, uint elem) public {
        uint32 i = find(queue, elem);
        uint32 end = queue._begin + queue._size;
        while (i < end - 1) {
            queue._data[i % MAX_SIZE] = queue._data[(i + 1) % MAX_SIZE];
            i++;
        }
        queue._size--;
    }
}


contract Vote is ERC20Snapshot {
    using ArrayQueue for ArrayQueue.Queue;


    event Created(uint256 indexed hash);
    event Accepted(uint256 indexed hash);
    event Rejected(uint256 indexed hash);
    event Discarded(uint256 indexed hash);

    error ZeroBalance();
    error MaxProposals();
    error ProposalNotFound();
    error ProposalAlreadyExists();



    mapping(uint => Proposal) private _proposals;
    ArrayQueue.Queue private _proposalsQueue;


    constructor() ERC20("Vote", "VOT") {
        _mint(msg.sender, TOTAL_SUPPLY * 10**DECIMALS);
    }


    modifier onlyTokenOwner {
        // Allow only users with non-zero balance
        if (balanceOf(msg.sender) == 0) {
            revert ZeroBalance();
        }
        _;
    }

    modifier checkMaxProposals() {
        if (_proposalsQueue.size() == MAX_PROPOSALS) {
            // Maximum amount of proposals achieved
            // Try discard the oldest one
            if (!tryDiscard(_proposalsQueue.first())) {
                // Could not discard oldest proposal and thus we can not add a new one
                revert MaxProposals();
            }
        }
        _;
    }

    function removeProposal(uint proposalHash) private {
        delete _proposals[proposalHash];
        _proposalsQueue.remove(proposalHash);
    }

    function tryDiscard(uint proposalHash) private returns (bool) {
        if (block.timestamp - _proposals[proposalHash].timestamp > PROPOSAL_TTL) {
            emit Discarded(proposalHash);
            removeProposal(proposalHash);
            return true;
        }

        return false;
    }

    modifier ensureExists(uint hash) {
        if(_proposals[hash] == 0) {
            revert ProposalNotFound();
        }
        _;
    }

    modifier ensureNotExists(uint hash) {
        if(_proposals[hash] != 0) {
            revert ProposalAlreadyExists();
        }
        _;
    }

    function createProposal(uint hash) public onlyTokenOwner checkMaxProposals ensureNotExists {
        _proposals[hash] = Proposal({
            hash: hash,
            timestamp: block.timestamp,
            snapshotId: _snapshot()
        });
        _proposalsQueue.add(hash);

        emit Created(hash);
    }


    uint private constant TO_ACCEPT = REQUIRED_FOR_DECISION * 10**DECIMALS;
    uint private constant TO_NOT_ACCEPT = (TOTAL_SUPPLY - REQUIRED_FOR_DECISION) * 10**DECIMALS;
    function vote(uint hash, bool voteFor) internal ensureExists(hash) {
        if (tryDiscard(hash)) {
            // Proposal was discarded, no further action needed
            return;
        }
        Proposal storage proposal = _proposals[hash];

        require(!proposal.voted[msg.sender], "Already voted");

        uint balance = balanceOfAt(msg.sender, proposal.snapshotId);

        require(balance > 0, "Zero balance");

        proposal.voted[msg.sender] = true;
        if (voteFor) {
            proposal.votesFor += balance;

            if (proposal.votesFor > TO_ACCEPT) {
                emit Accepted(hash);
                removeProposal(hash);
            }
        } else {
            proposal.votesAgainst += balance;

            if (proposal.votesAgainst > TO_ACCEPT) {
                emit Rejected(hash);
                removeProposal(hash);
            }
        }
    }
}