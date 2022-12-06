const {
    time,
    loadFixture,
} = require("@nomicfoundation/hardhat-network-helpers");
const {revertedWithCustomError} = require("@nomicfoundation/hardhat-chai-matchers")
const {expect} = require("chai");
const {ethers} = require("hardhat");


describe("Vote", function () {
    let DECIMALS = 6
    let TOTAL_SUPPLY = 100;
    let MAX_PROPOSALS = 3;

    // We define a fixture to reuse the same setup in every test.
    // We use loadFixture to run this setup once, snapshot that state,
    // and reset Hardhat Network to that snapshot in every test.
    async function deployVoteFixture() {
        // Contracts are deployed using the first signer/account by default
        const [owner, address1, address2] = await ethers.getSigners();

        const queueFactory = await ethers.getContractFactory("ArrayQueue");
        const queue = await queueFactory.deploy();

        const voteFactory = await ethers.getContractFactory("Vote", {
            libraries: {
                ArrayQueue: queue.address,
            }
        });
        const vote = await voteFactory.deploy();
        return {vote, owner, address1, address2};
    }

    let vote
    let owner
    let address1

    beforeEach(async function() {
        let {vote: vote_, owner: owner_, address1: address1_} = await loadFixture(deployVoteFixture);
        vote = vote_
        owner = owner_
        address1 = address1_
    })

    async function expectReverted(request, errorName) {
        await expect(request).to.be.revertedWithCustomError(vote, errorName);
    }

    async function expectEmit(request, eventName, ...args) {
        await expect(request).to.emit(vote, eventName).withArgs(...args);
    }

    async function transfer(from, to, amount) {
        amount *= 10 ** DECIMALS
        await expect(vote.connect(from).transfer(to.address, amount))
            .to.emit(vote, "Transfer")
            .withArgs(from.address, to.address, amount)
    }

    describe("Deployment", function () {
        it("Should set the right total supply", async function () {
            const {vote} = await loadFixture(deployVoteFixture);

            expect(await vote.totalSupply()).to.equal(TOTAL_SUPPLY * 10**DECIMALS);
        });

        it("Should mint tokens to owner", async function () {
            const {vote, owner} = await loadFixture(deployVoteFixture);

            expect(await vote.balanceOf(owner.address)).to.equal(TOTAL_SUPPLY * 10**DECIMALS);
        });
    });

    // In these tests only one account is voting with all 100 tokens
    describe("Events", function() {

        it("Should emit event on create", async function () {
            await expectEmit(vote.createProposal(1), "Created", 1);
        })

        it("Should emit event on accept", async function () {
          await expectEmit(vote.createProposal(1), "Created", 1);
          await expectEmit(vote.voteFor(1), "Accepted", 1);
        })

        it("Should emit event on reject", async function () {
          await expectEmit(vote.createProposal(1), "Created", 1);
          await expectEmit(vote.voteAgainst(1), "Declined", 1);
        })

        it("Should emit event on discard", async function () {
          await expectEmit(vote.createProposal(1), "Created", 1);
          await time.increase(4 * 24 * 60 * 60);
          await expectEmit(vote.voteFor(1), "Discarded", 1);
        })
    });

    describe("Basic reverts", function () {
        it("Should not create zero-hash proposal", async function () {
            await expectReverted(vote.createProposal(0), "ZeroHash");
        });

        it("Should not vote for/against zero-hash proposal", async function () {
            await expectReverted(vote.voteFor(0), "ProposalNotFound");
            await expectReverted(vote.voteAgainst(0), "ProposalNotFound");
        });

        it("Should not vote for non existing proposal", async function () {
            await expectReverted(vote.voteFor(1), "ProposalNotFound");
            await expectReverted(vote.voteAgainst(1), "ProposalNotFound");
        });

        it("Should not create proposal with zero balance", async function () {
            expect(await vote.balanceOf(address1.address)).to.equal(0)
            await expectReverted(vote.connect(address1).createProposal(1), "ZeroBalance")
        });

        it("Should not vote with zero balance", async function () {
            expect(await vote.balanceOf(address1.address)).to.equal(0)
            await expectEmit(vote.createProposal(1), "Created", 1)
            await expectReverted(vote.connect(address1).createProposal(1), "ZeroBalance")
        });

        it("Should not create same proposal twice", async function () {
            await expectEmit(vote.createProposal(1), "Created", 1)
            await expectReverted(vote.createProposal(1), "ProposalAlreadyExists")
        });

        it("Should not create too many proposals", async function () {
            for (let i = 0; i < MAX_PROPOSALS; i++) {
                await expectEmit(vote.createProposal(i + 1), "Created", i + 1)
            }
            await expectReverted(vote.createProposal(MAX_PROPOSALS + 1), "MaxProposals")
        });
    });

    describe("Snapshots", function () {
        it("Should use balance from correct snapshot", async function () {
            const alice = vote.connect(owner)
            const bob = vote.connect(address1)

            await expectEmit(alice.createProposal(1), "Created", 1)
            await transfer(owner, address1, TOTAL_SUPPLY);
            await expectReverted(bob.voteFor(1), "ZeroBalance");
            await expectEmit(alice.voteFor(1), "Accepted", 1);

            await expectEmit(bob.createProposal(2), "Created", 2);
            await transfer(address1, owner, TOTAL_SUPPLY);
            await expectReverted(alice.voteFor(2), "ZeroBalance");
            await expectEmit(bob.voteFor(2), "Accepted", 2);
        });
    });

    describe("Queue", function () {
        it("Should discard most obsolete proposals on creation", async function () {
            for (let i = 0; i < MAX_PROPOSALS; i++) {
                await expectEmit(vote.createProposal(i + 1), "Created", i + 1);
            }
            await time.increase(4 * 24 * 60 * 60);
            for (let i = 0; i < MAX_PROPOSALS; i++) {
                await expectEmit(vote.createProposal(MAX_PROPOSALS + i + 1), "Discarded", i + 1);
            }
        })

        it("Proposals list getter", async function () {
            const proposalsList = []
            for (let i = 0; i < MAX_PROPOSALS; i++) {
                await expectEmit(vote.createProposal(i + 1), "Created", i + 1);
                proposalsList.push(ethers.BigNumber.from(i + 1))
                expect(await vote.listProposals()).deep.to.equal(proposalsList)
            }
        })
    })

    // Stress test that consists of creation and acceptance of random proposals
    // To estimate gas usage
    describe("Stress test", function () {
        it("Calculate gas", async function () {
            const proposals = new Set()
            let gasUsed = ethers.BigNumber.from("0")

            async function addGas(transactionPromise) {
                const transaction = await transactionPromise
                const receipt = await transaction.wait()
                gasUsed = gasUsed.add(receipt.gasUsed)
            }

            async function addProposal(i) {
                proposals.add(i)
                await addGas(vote.createProposal(i))
            }

            async function acceptRandomProposal() {
                const proposalsArr = [...proposals.keys()]
                const randIdx = Math.floor(Math.random() * proposalsArr.length);
                const randomProposal = proposalsArr[randIdx]

                proposals.delete(randomProposal)
                await addGas(vote.voteFor(randomProposal))
            }

            for (let iter = 1; iter <= 500; iter++) {
                if (proposals.size === 0) {
                    await addProposal(iter)
                } else if (proposals.size === MAX_PROPOSALS) {
                    await acceptRandomProposal()
                } else if (Math.random() > 0.5) {
                    await acceptRandomProposal()
                } else {
                    await addProposal(iter)
                }
            }

            console.log("Gas used: ", gasUsed.toString())
        });
    })
});
