const {
  ethers
} = require("@nomiclabs/buidler");
const {
  expect
} = require("chai");

const {
  time
} = require("@openzeppelin/test-helpers");

const COORDINATOR_1_URL = "https://hermez.io";
const COORDINATOR_1_URL_2 = "https://new.hermez.io";
const bootCoordinatorURL = "https://boot.coordinator.io";

const BLOCKS_PER_SLOT = 40;
const TIMEOUT = 40000;

const MIN_BLOCKS = 81;

let ABIbid = [
  "function bid(uint128 slot, uint128 bidAmount)",
  "function multiBid(uint128 startingSlot,uint128 endingSlot,bool[6] slotEpoch,uint128 maxBid,uint128 minBid)",
];
let iface = new ethers.utils.Interface(ABIbid);

describe("Auction Protocol", function() {
  this.timeout(TIMEOUT);

  let buidlerHEZToken;
  let buidlerHermezAuctionProtocol;
  let owner,
    coordinator1,
    forger1,
    coordinator2,
    forger2,
    registryFunder,
    hermezRollup,
    bootCoordinator,
    donation,
    governance;

  let governanceAddress, hermezRollupAddress, donationAddress,coordinator1Address;

  // Deploy
  before(async function() {
    const HEZToken = await ethers.getContractFactory("HEZTokenMockFake");

    [
      owner,
      coordinator1,
      forger1,
      coordinator2,
      forger2,
      producer2,
      registryFunder,
      hermezRollup,
      donation,
      governance,
      bootCoordinator,
      ...addrs
    ] = await ethers.getSigners();

    governanceAddress = await governance.getAddress();
    bootCoordinator = await governance.getAddress();
    hermezRollupAddress = await hermezRollup.getAddress();
    donationAddress = await donation.getAddress();
    coordinator1Address = await coordinator1.getAddress();

    buidlerHEZToken = await HEZToken.deploy(await owner.getAddress());
    await buidlerHEZToken.deployed();
    // Send tokens to coordinators addresses
    await buidlerHEZToken
      .connect(owner);

    await buidlerHEZToken
      .connect(owner)
      .transfer(
        await coordinator1.getAddress(),
        ethers.utils.parseEther("10000")
      );

    await buidlerHEZToken
      .connect(owner)
      .transfer(
        await coordinator2.getAddress(),
        ethers.utils.parseEther("10000")
      );
  });

  beforeEach(async function() {
    const HermezAuctionProtocol = await ethers.getContractFactory(
      "HermezAuctionProtocol"
    );

    buidlerHermezAuctionProtocol = await HermezAuctionProtocol.deploy();
    await buidlerHermezAuctionProtocol.deployed();

    // Wait for pending blocks
    let current = await time.latestBlock();
    time.advanceBlock();
    let latest = (await time.latestBlock()).toNumber();
    while (current >= latest) {
      sleep(100);
      latest = (await time.latestBlock()).toNumber();
    }

    await expect(
      buidlerHermezAuctionProtocol.hermezAuctionProtocolInitializer(
        buidlerHEZToken.address,
        latest + (MIN_BLOCKS - 10),
        hermezRollupAddress,
        governanceAddress,
        donationAddress,
        bootCoordinator,
        bootCoordinatorURL
      )
    ).to.be.revertedWith("HermezAuctionProtocol::hermezAuctionProtocolInitializer GENESIS_BELOW_MINIMAL");

    await buidlerHermezAuctionProtocol.hermezAuctionProtocolInitializer(
      buidlerHEZToken.address,
      latest + 1 + MIN_BLOCKS,
      hermezRollupAddress,
      governanceAddress,
      donationAddress,
      bootCoordinator,
      bootCoordinatorURL
    );
  });

  it("shouldn't be able to initialize twice", async function() {
    await expect(
      buidlerHermezAuctionProtocol.hermezAuctionProtocolInitializer(
        buidlerHEZToken.address,
        MIN_BLOCKS,
        hermezRollupAddress,
        governanceAddress,
        donationAddress,
        bootCoordinator,
        bootCoordinatorURL
      )
    ).to.be.revertedWith("Initializable: contract is already initialized");
  });

  describe("Coordinator registration", function() {
    beforeEach(async function() {
      // Register Coordinator
      await buidlerHermezAuctionProtocol
        .connect(coordinator1)
        .setCoordinator(await forger1.getAddress(), COORDINATOR_1_URL);
    });
    it("should register a producer/coordinator", async function() {
      // Get registered coordinator
      let coordinator = await buidlerHermezAuctionProtocol.coordinators(
        await coordinator1.getAddress()
      );
      // Check coordinator withdrawal address
      expect(coordinator.forger).to.equal(
        await forger1.getAddress()
      );
      // Check coordinator URL
      expect(coordinator.coordinatorURL).to.equal(COORDINATOR_1_URL);
    });
    it("should be able to change a register a forger", async function() {

      await expect (
        buidlerHermezAuctionProtocol
          .connect(coordinator1)
          .setCoordinator(await forger2.getAddress(), ""))
        .to.be.revertedWith("HermezAuctionProtocol::setCoordinator: NOT_VALID_URL");

      // Register Coordinator
      await buidlerHermezAuctionProtocol
        .connect(coordinator1)
        .setCoordinator(await forger2.getAddress(), COORDINATOR_1_URL_2);

      // Get registered coordinator
      let coordinator = await buidlerHermezAuctionProtocol.coordinators(
        await coordinator1.getAddress()
      );
      // Check coordinator withdrawal address
      expect(coordinator.forger).to.equal(
        await forger2.getAddress()
      );
      // Check coordinator URL
      expect(coordinator.coordinatorURL).to.equal(COORDINATOR_1_URL_2);
    });
  });

  describe("Send HEZ", function() {
    // Register Coordinator
    beforeEach(async function() {
      await buidlerHermezAuctionProtocol
        .connect(coordinator1)
        .setCoordinator(await forger1.getAddress(), COORDINATOR_1_URL);
      await buidlerHEZToken.connect(coordinator1).approve(buidlerHermezAuctionProtocol.address,ethers.BigNumber.from("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"));
    });

    it("should send 10 HEZ to the contract", async function() {
      let amount = ethers.utils.parseEther("15");
      let slot = 10;
      let permit = ethers.utils.toUtf8Bytes("");

      // Call processBid
      await expect(
        buidlerHermezAuctionProtocol
          .connect(coordinator1)
          .processBid(amount,slot,amount,permit)
      ).to.emit(buidlerHermezAuctionProtocol,"NewBid").withArgs(slot,amount,coordinator1Address);
    });
  });

  describe("Slot info", function() {
    it("should return slot 0 before starting", async function() {
      // Get current slot number
      expect(
        await buidlerHermezAuctionProtocol.getCurrentSlotNumber()
      ).to.be.equal(0);

      let genesis = (
        await buidlerHermezAuctionProtocol.genesisBlock()
      ).toNumber();
      // Advance to block genesis - 40
      await time.advanceBlockTo(genesis - 40);
      // Check that the current slot is still 0 (Delay Genesis)
      expect(
        await buidlerHermezAuctionProtocol.getCurrentSlotNumber()
      ).to.be.equal(0);
    });
    it("should return the correct slot at #1150=>0, #1205=>1, #1245=>2, #1365=>5, #1565=>10 starting at block #1150", async function() {
      let relative_block = 15;
      // Get starting Block
      let startingBlock = (
        await buidlerHermezAuctionProtocol.genesisBlock()
      ).toNumber();
      // Advance blocks
      await time.advanceBlockTo(startingBlock + relative_block);
      // Check current slot
      expect(
        await buidlerHermezAuctionProtocol.getCurrentSlotNumber()
      ).to.be.equal(
        Math.floor(
          ((await time.latestBlock()) - startingBlock) / BLOCKS_PER_SLOT
        )
      );

      // Advance blocks to next slot
      slot_step = 1;
      await time.advanceBlockTo(
        (await time.latestBlock()).toNumber() + slot_step * BLOCKS_PER_SLOT
      );
      expect(
        await buidlerHermezAuctionProtocol.getCurrentSlotNumber()
      ).to.be.equal(
        Math.floor(
          ((await time.latestBlock()) - startingBlock) / BLOCKS_PER_SLOT
        )
      );

      // Advance blocks to next slot
      slot_step = 1;
      await time.advanceBlockTo(
        (await time.latestBlock()).toNumber() + slot_step * BLOCKS_PER_SLOT
      );
      expect(
        await buidlerHermezAuctionProtocol.getCurrentSlotNumber()
      ).to.be.equal(
        Math.floor(
          ((await time.latestBlock()) - startingBlock) / BLOCKS_PER_SLOT
        )
      );

      // Advance blocks of 3 slots
      slot_step = 3;
      await time.advanceBlockTo(
        (await time.latestBlock()).toNumber() + slot_step * BLOCKS_PER_SLOT
      );
      expect(
        await buidlerHermezAuctionProtocol.getCurrentSlotNumber()
      ).to.be.equal(
        Math.floor(
          ((await time.latestBlock()) - startingBlock) / BLOCKS_PER_SLOT
        )
      );

      // Advance blocks of 5 slots
      slot_step = 5;
      await time.advanceBlockTo(
        (await time.latestBlock()).toNumber() + slot_step * BLOCKS_PER_SLOT
      );
      expect(
        await buidlerHermezAuctionProtocol.getCurrentSlotNumber()
      ).to.be.equal(
        Math.floor(
          ((await time.latestBlock()) - startingBlock) / BLOCKS_PER_SLOT
        )
      );
    });
  });
});

function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}