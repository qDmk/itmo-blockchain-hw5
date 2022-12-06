pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";

import "hardhat/console.sol";

uint8 constant DECIMALS = 6;
uint8 constant TOTAL_SUPPLY = 100;         // Total token supply. Raw value, without decimal part
uint8 constant REQUIRED_FOR_DECISION = 50;
uint32 constant PROPOSAL_TTL = 3 days;
uint8 constant MAX_PROPOSALS = 3;         // Maximal amount of proposals at the same time

/// @dev Queue implementation on array for storing elements in order and removing elements from any place
library ArrayQueue {
    uint32 constant MAX_SIZE = MAX_PROPOSALS;

    error EmptyQueue();
    error FullQueue();
    error ElementNotFound();

    struct Queue {
        uint64[MAX_SIZE] _data;
        uint32 _begin;
        uint32 _size;
    }

    function empty(Queue storage queue) public view returns (bool) {
        return queue._size == 0;
    }

    function size(Queue storage queue) public view returns (uint32) {
        return queue._size;
    }

    function asArray(Queue storage queue) public view returns (uint64[] memory) {
        uint64[] memory dump = new uint64[](queue._size);

        for (uint32 i = 0; i < queue._size; i++) {
            dump[i] = queue._data[i];
        }

        return dump;
    }

    function first(Queue storage queue) public view returns (uint64) {
        if (size(queue) == 0) {
            revert EmptyQueue();
        }

        return queue._data[queue._begin];
    }

    /// @dev Adds element to the end
    function add(Queue storage queue, uint64 elem) public {
        if (size(queue) == MAX_SIZE) {
            revert FullQueue();
        }
        queue._data[queue._size] = elem;
        queue._size++;
    }

    /// @dev Finds element index
    /// Reverts if element not found
    function find(Queue storage queue, uint64 elem) private view returns (uint32) {
        for (uint32 i = 0; i < queue._size; i++) {
            if (queue._data[i] == elem) {
                return i;
            }
        }

        revert ElementNotFound();
    }

    /// @dev Removes element from the queue
    /// Reverts if element not found
    function remove(Queue storage queue, uint64 elem) public {
        uint32 i = find(queue, elem);
        while (i < queue._size - 1) {
            queue._data[i] = queue._data[i + 1];
            i++;
        }
        queue._data[queue._size - 1] = 0;
        queue._size--;
    }
}

contract Vote is ERC20Snapshot {
    using ArrayQueue for ArrayQueue.Queue;

    /// @notice Emitted when new proposal is created
    event Created(uint64 indexed hash);

    /// @notice Emitted when proposal is accepted
    event Accepted(uint64 indexed hash);

    /// @notice Emitted when proposal is declined
    event Declined(uint64 indexed hash);

    /// @notice Emitted when proposal is discarded
    event Discarded(uint64 indexed hash);

    /// @notice Proposal's hash is zero
    error ZeroHash();

    /// @notice Voter have no tokens
    error ZeroBalance();

    /// @notice Max proposal amount created
    error MaxProposals();

    /// @notice Vote for non existing proposal
    error ProposalNotFound();

    /// @notice Proposal with this hash already exists
    error ProposalAlreadyExists();

    /// @notice Voter have already voted for this proposal
    error AlreadyVoted();

    /// @dev We do not store hash here since it is always known from elsewhere (given by user or taken from queue)
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

    /// @dev Hash to proposal mapping
    mapping(uint64 => Proposal) public proposals;

    /// @dev Queue of proposal hashes
    ArrayQueue.Queue private _proposalsQueue;


    constructor() ERC20("Vote", "VOT") {
        _mint(msg.sender, TOTAL_SUPPLY * 10 ** DECIMALS);
    }

    /// @dev Allow only users with non-zero balance
    modifier onlyTokenOwner {
        if (balanceOf(msg.sender) == 0) {
            revert ZeroBalance();
        }
        _;
    }

    /// @dev Hash can not be zero
    modifier onlyNonZero(uint64 hash) {
        if (hash == 0) {
            revert ZeroHash();
        }
        _;
    }

    /// @dev Check if proposal with such hash exists
    modifier ensureExists(uint64 hash) {
        // If proposal exists it has non zero timestamp
        if (proposals[hash].createdTimestamp == 0) {
            revert ProposalNotFound();
        }
        _;
    }

    /// @dev Check if proposal with such does not exists
    modifier ensureNotExists(uint64 hash) {
        // If proposal exists it has non zero timestamp
        if (proposals[hash].createdTimestamp != 0) {
            revert ProposalAlreadyExists();
        }
        _;
    }

    /// @dev Ensure that there is space for new proposal. Tires discard the most obsolete proposal if there is one
    modifier checkMaxProposals() {
        if (_proposalsQueue.size() == MAX_PROPOSALS) {
            // Maximum amount of proposals achieved
            // Try discard the oldest one
            uint64 mostObsolete = _proposalsQueue.first();
            if (!tryDiscard(mostObsolete)) {

                // Could not discard oldest proposal and thus we can not add a new one
                revert MaxProposals();
            }
        }
        _;
    }

    /// @dev Removes proposal from mapping and its hash from queue
    function removeProposal(uint64 proposalHash) private {
        _proposalsQueue.remove(proposalHash);
        delete proposals[proposalHash];
    }

    /// @dev Check whether this proposal is obsolete. Discards it if so
    function tryDiscard(uint64 hash) private returns (bool) {
        if (block.timestamp - proposals[hash].createdTimestamp > PROPOSAL_TTL) {
            emit Discarded(hash);
            removeProposal(hash);
            return true;
        }

        return false;
    }

    /// @notice Get all proposals that are in the queue now
    function listProposals() public view returns (uint64[] memory) {
        return _proposalsQueue.asArray();
    }

    /// @notice Publish new proposal
    function createProposal(uint64 hash) public
        onlyNonZero(hash)
        onlyTokenOwner
        ensureNotExists(hash)
        checkMaxProposals
    {
        Proposal storage proposal = proposals[hash];
        proposal.createdTimestamp = uint64(block.timestamp);
        proposal.snapshotId = uint64(_snapshot());

        _proposalsQueue.add(hash);

        emit Created(hash);
    }


    uint private constant THRESHHOLD = REQUIRED_FOR_DECISION * 10 ** DECIMALS;

    function vote(uint64 hash, bool isVoteFor) internal
        ensureExists(hash)
    {
        // Check if proposal is not obsolete
        if (tryDiscard(hash)) {
            // Proposal was discarded, no further action needed
            return;
        }

        // Proposal is not obsolete
        Proposal storage proposal = proposals[hash];

        // Ensure sender have not voted yet
        if (proposal.voted[msg.sender]) {
            revert AlreadyVoted();
        }

        // Ensure voter had any tokens at the moment of creation proposal
        uint64 balance = uint64(balanceOfAt(msg.sender, proposal.snapshotId));
        if (balance == 0) {
            revert ZeroBalance();
        }

        if (isVoteFor) {
            proposal.votesFor += balance;

            if (proposal.votesFor > THRESHHOLD) {

                // Accept proposal
                emit Accepted(hash);
                removeProposal(hash);
                return;
            }
        } else {
            proposal.votesAgainst += balance;

            if (proposal.votesAgainst > THRESHHOLD) {
                // Decline proposal
                emit Declined(hash);
                removeProposal(hash);
                return;
            }
        }

        // Mark that sender have voted
        proposal.voted[msg.sender] = true;
    }

    /// @notice Vote for proposal
    function voteFor(uint64 hash) public {
        vote(hash, true);
    }

    /// @notice Vote against proposal
    function voteAgainst(uint64 hash) public {
        vote(hash, false);
    }
}