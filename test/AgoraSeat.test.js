const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 86400;
const YEAR = 365 * DAY;
const E = (n) => ethers.parseEther(String(n));

describe("AgoraSeat", function () {
  let as, owner, ann, ben, cara;

  beforeEach(async () => {
    [owner, ann, ben, cara] = await ethers.getSigners();
    const F = await ethers.getContractFactory("AgoraSeat");
    as = await F.deploy();
    await as.waitForDeployment();
  });

  // 10% a year. A seat priced at 10 BOT costs 1 BOT of tax a year.
  async function newSeat(price = "10", escrow = "1", who = ann) {
    await as.connect(who).createSeat("Keeper of the Water Clock", E(price), "on duty", { value: E(escrow) });
    return (await as.seatCount()) - 1n;
  }

  it("creates a seat at a self-assessed price", async () => {
    const id = await newSeat();
    const s = await as.getSeat(id);
    expect(s.holder).to.equal(ann.address);
    expect(s.title).to.equal("Keeper of the Water Clock");
    expect(s.selfPrice).to.equal(E(10));
    expect(s.escrow).to.equal(E(1));
    expect(await as.lockedTotal()).to.equal(E(1));
  });

  it("insists the escrow covers at least a week of tax", async () => {
    // A week of tax on 10 BOT at 10% a year is roughly 0.0192 BOT.
    await expect(
      as.connect(ann).createSeat("x", E(10), "", { value: E("0.001") })
    ).to.be.revertedWith("escrow below a week of tax");
    await expect(as.connect(ann).createSeat("", E(10), "", { value: E(1) })).to.be.revertedWith("bad title");
    await expect(as.connect(ann).createSeat("x", 0, "", { value: E(1) })).to.be.revertedWith("price zero");
  });

  it("draws tax from the escrow as time passes", async () => {
    const id = await newSeat("10", "1");
    await time.increase(YEAR / 2);

    const owed = await as.taxOwed(id);
    expect(owed).to.be.closeTo(E("0.5"), E("0.0001"));

    await as.connect(cara).collectTax(id); // permissionless
    const s = await as.getSeat(id);
    expect(s.escrow).to.be.closeTo(E("0.5"), E("0.0001"));
    expect(await as.accumulatedFees()).to.be.closeTo(E("0.5"), E("0.0001"));
    expect(await as.taxOwed(id)).to.equal(0);
  });

  it("lets anyone buy at the holder's own price", async () => {
    const id = await newSeat("10", "1");
    await expect(
      as.connect(ben).buySeat(id, E(20), "mine now", { value: E(5) })
    ).to.be.revertedWith("send the asking price");

    // 10 to buy, 1 of escrow for a 20 BOT assessment.
    await as.connect(ben).buySeat(id, E(20), "mine now", { value: E(11) });

    const s = await as.getSeat(id);
    expect(s.holder).to.equal(ben.address);
    expect(s.selfPrice).to.equal(E(20));
    expect(s.escrow).to.equal(E(1));
    expect(s.message).to.equal("mine now");
    expect(s.transfers).to.equal(1);

    // Ann is credited the price plus whatever escrow she had left.
    const credit = await as.creditOf(ann.address);
    expect(credit).to.be.closeTo(E(11), E("0.01"));
    await expect(as.connect(ann).withdraw()).to.changeEtherBalance(ann, credit);
  });

  it("settles the outgoing holder's tax before the sale, so arrears are never inherited", async () => {
    const id = await newSeat("10", "1");
    await time.increase(YEAR / 2);
    await as.connect(ben).buySeat(id, E(10), "", { value: E(11) });

    // Ann's half-year of tax came out of her escrow, not Ben's.
    expect(await as.accumulatedFees()).to.be.closeTo(E("0.5"), E("0.001"));
    expect(await as.creditOf(ann.address)).to.be.closeTo(E("10.5"), E("0.001"));
    expect((await as.getSeat(id)).escrow).to.equal(E(1));
    expect(await as.taxOwed(id)).to.equal(0);
  });

  it("will not let you buy your own seat or run on too little escrow", async () => {
    const id = await newSeat("10", "1");
    await expect(as.connect(ann).buySeat(id, E(20), "", { value: E(11) })).to.be.revertedWith("already yours");
    // Buying at 10 and assessing at 10,000 leaves nothing like a week of tax.
    await expect(
      as.connect(ben).buySeat(id, E(10000), "", { value: E("10.01") })
    ).to.be.revertedWith("escrow below a week of tax");
  });

  it("makes raising your own price cost you escrow", async () => {
    const id = await newSeat("10", "1");
    await expect(as.connect(ben).setPrice(id, E(20))).to.be.revertedWith("not the holder");

    await as.connect(ann).setPrice(id, E(100));
    expect((await as.getSeat(id)).selfPrice).to.equal(E(100));

    // A week of tax on 2000 BOT is about 3.8 BOT, far more than the escrow left.
    await expect(as.connect(ann).setPrice(id, E(2000))).to.be.revertedWith("escrow below a week of tax");
    await as.connect(ann).depositEscrow(id, { value: E(5) });
    await as.connect(ann).setPrice(id, E(2000));
    expect((await as.getSeat(id)).selfPrice).to.equal(E(2000));
  });

  it("forecloses a seat whose escrow runs dry", async () => {
    const id = await newSeat("10", "1");
    expect(await as.isForeclosed(id)).to.equal(false);

    await time.increase(YEAR + DAY); // a year of tax on 1 BOT of escrow
    expect(await as.isForeclosed(id)).to.equal(true);

    await as.connect(cara).collectTax(id);
    const s = await as.getSeat(id);
    expect(s.selfPrice).to.equal(0);
    expect(s.escrow).to.equal(0);
    expect(s.holder).to.equal(ann.address); // still sitting there, but free to take
    expect(await as.accumulatedFees()).to.equal(E(1));
  });

  it("hands a foreclosed seat to whoever turns up with an escrow", async () => {
    const id = await newSeat("10", "1");
    await time.increase(YEAR + DAY);

    // Nothing to pay the old holder — the price is zero.
    await as.connect(ben).buySeat(id, E(5), "new keeper", { value: E("0.5") });
    const s = await as.getSeat(id);
    expect(s.holder).to.equal(ben.address);
    expect(s.selfPrice).to.equal(E(5));
    expect(s.escrow).to.equal(E("0.5"));
    expect(await as.creditOf(ann.address)).to.equal(0);
  });

  it("lets anyone top up a seat's escrow", async () => {
    const id = await newSeat("10", "1");
    await as.connect(cara).depositEscrow(id, { value: E(2) });
    expect((await as.getSeat(id)).escrow).to.be.closeTo(E(3), E("0.001"));
    await expect(as.connect(cara).depositEscrow(id, { value: 0 })).to.be.revertedWith("nothing sent");
  });

  it("reports coverage that matches when foreclosure actually happens", async () => {
    const id = await newSeat("10", "1");
    const cover = await as.coverageSeconds(id);
    expect(cover).to.be.closeTo(YEAR, 60);

    await time.increase(Number(cover) - 2 * DAY);
    expect(await as.isForeclosed(id)).to.equal(false);
    await time.increase(3 * DAY);
    expect(await as.isForeclosed(id)).to.equal(true);
  });

  it("keeps the message with the holder", async () => {
    const id = await newSeat("10", "1");
    await expect(as.connect(ben).updateMessage(id, "nope")).to.be.revertedWith("not the holder");
    await as.connect(ann).updateMessage(id, "water clock reset at dawn");
    expect((await as.getSeat(id)).message).to.equal("water clock reset at dawn");
    await expect(as.connect(ann).updateMessage(id, "x".repeat(200))).to.be.revertedWith("message too long");
  });

  it("pauses new seats and sales but never tax, escrow or withdrawal", async () => {
    const id = await newSeat("10", "1");
    await as.connect(ben).buySeat(id, E(10), "", { value: E(11) });
    await as.connect(owner).pause();

    await expect(
      as.connect(cara).createSeat("x", E(1), "", { value: E(1) })
    ).to.be.revertedWithCustomError(as, "EnforcedPause");
    await expect(as.connect(cara).buySeat(id, E(10), "", { value: E(11) })).to.be.revertedWithCustomError(
      as,
      "EnforcedPause"
    );

    await as.connect(cara).collectTax(id);
    await as.connect(ben).depositEscrow(id, { value: E(1) });
    await as.connect(ann).withdraw();
  });

  it("caps the tax rate and keeps fees separate from escrow", async () => {
    await expect(as.connect(owner).setTaxRateBps(9000)).to.be.revertedWith("rate too high");
    await expect(as.connect(ann).setTaxRateBps(2000)).to.be.revertedWithCustomError(
      as,
      "OwnableUnauthorizedAccount"
    );
    await as.connect(owner).setTaxRateBps(2000);
    expect(await as.taxRateBps()).to.equal(2000);

    const id = await newSeat("10", "2");
    await time.increase(YEAR / 2);
    await as.connect(cara).collectTax(id);

    const fees = await as.accumulatedFees();
    expect(fees).to.be.closeTo(E(1), E("0.001")); // 20% of 10 for half a year
    await expect(as.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(as, -fees);

    // The rest of the escrow is still on the seat.
    expect(await ethers.provider.getBalance(await as.getAddress())).to.equal(await as.lockedTotal());
  });

  it("tracks seats held and lists them newest first", async () => {
    const a = await newSeat("10", "1", ann);
    const b = await newSeat("5", "1", ben);
    await as.connect(cara).buySeat(a, E(10), "", { value: E(11) });

    expect((await as.seatsHeldBy(cara.address)).map(Number)).to.deep.equal([Number(a)]);
    expect((await as.getRecent(2)).map(Number)).to.deep.equal([Number(b), Number(a)]);
  });

  it("will not let the owner reach escrow or credits through withdrawFees", async () => {
    const id = await newSeat("10", "1");
    await as.connect(ben).buySeat(id, E(10), "", { value: E(11) });

    // Everything the contract holds is either escrow, a credit owed, or tax
    // already drawn. Nothing else.
    const held = await ethers.provider.getBalance(await as.getAddress());
    expect(held).to.equal((await as.lockedTotal()) + (await as.accumulatedFees()));

    // Sweeping fees leaves the escrow and Ann's credit fully covered.
    await as.connect(owner).withdrawFees(owner.address);
    expect(await ethers.provider.getBalance(await as.getAddress())).to.equal(await as.lockedTotal());
    expect(await as.lockedTotal()).to.equal((await as.getSeat(id)).escrow + (await as.creditOf(ann.address)));
  });
});
