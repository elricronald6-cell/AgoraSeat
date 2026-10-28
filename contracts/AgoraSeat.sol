// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title AgoraSeat
 * @notice Self-assessed seats on BOT Chain, held under a continuous tax.
 *
 * A seat is a named position — a title, a slot, a spot on a wall — that one
 * address holds at a time. The holder names their own price and pays a running
 * tax on that number. Anyone may buy the seat at the holder's own price, at any
 * moment, without asking.
 *
 * That pairing is the whole mechanism. Price it low and somebody takes it from
 * you cheaply. Price it high and the tax bleeds you. The honest valuation is
 * the only comfortable one, and nobody has to referee it.
 *
 * Tax is drawn from a prepaid escrow. Let the escrow run dry and the seat
 * forecloses: its price drops to zero and the next person takes it for the cost
 * of their own escrow. Foreclosure is the only penalty — no court, no appeal.
 *
 * Proceeds are credited, not pushed. A holder whose address refuses payment
 * cannot wedge the seat shut for everyone else.
 */
contract AgoraSeat is Ownable, Pausable, ReentrancyGuard {
    struct Seat {
        address holder;
        uint256 selfPrice;
        uint256 escrow;
        uint64 lastTaxAt;
        uint64 createdAt;
        uint32 transfers;
        string title;
        string message;
    }

    uint64 public constant YEAR = 365 days;
    /// @notice Escrow must always cover at least this much tax at the current price.
    uint64 public constant MIN_COVER = 7 days;
    uint256 public constant MAX_TITLE = 48;
    uint256 public constant MAX_MESSAGE = 140;
    uint16 public constant MAX_TAX_BPS = 5000;

    /// @notice Annual tax on the self-assessed price.
    uint16 public taxRateBps = 1000;

    uint256 public accumulatedFees;
    /// @notice Escrow held plus proceeds not yet withdrawn.
    uint256 public lockedTotal;

    Seat[] private _seats;
    mapping(address => uint256) private _credits;
    mapping(address => uint256[]) private _seatsHeld;

    event SeatCreated(uint256 indexed seatId, address indexed holder, string title, uint256 price, uint256 escrow);
    event SeatBought(uint256 indexed seatId, address indexed from, address indexed to, uint256 price, uint256 newPrice);
    event PriceSet(uint256 indexed seatId, address indexed holder, uint256 price);
    event EscrowDeposited(uint256 indexed seatId, address indexed from, uint256 amount, uint256 escrow);
    event TaxCollected(uint256 indexed seatId, uint256 amount, uint256 escrowLeft);
    event Foreclosed(uint256 indexed seatId, address indexed holder);
    event MessageUpdated(uint256 indexed seatId, string message);
    event Credited(address indexed who, uint256 amount);
    event Withdrawn(address indexed who, uint256 amount);
    event TaxRateUpdated(uint16 taxRateBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // -------------------------------------------------------------- seats

    function createSeat(string calldata title, uint256 price, string calldata message)
        external
        payable
        whenNotPaused
        returns (uint256 seatId)
    {
        require(bytes(title).length > 0 && bytes(title).length <= MAX_TITLE, "bad title");
        require(bytes(message).length <= MAX_MESSAGE, "message too long");
        require(price > 0, "price zero");
        require(msg.value >= taxFor(price, MIN_COVER), "escrow below a week of tax");

        seatId = _seats.length;
        _seats.push(
            Seat({
                holder: msg.sender,
                selfPrice: price,
                escrow: msg.value,
                lastTaxAt: uint64(block.timestamp),
                createdAt: uint64(block.timestamp),
                transfers: 0,
                title: title,
                message: message
            })
        );
        _seatsHeld[msg.sender].push(seatId);
        lockedTotal += msg.value;
        emit SeatCreated(seatId, msg.sender, title, price, msg.value);
    }

    /**
     * @notice Take a seat at the price its holder set.
     * @param newPrice Your own self-assessment, effective immediately.
     * @dev Send the purchase price plus the escrow you want to run on. Tax is
     *      settled against the outgoing holder first, so you never inherit
     *      their arrears.
     */
    function buySeat(uint256 seatId, uint256 newPrice, string calldata newMessage)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        Seat storage s = _seat(seatId);
        require(msg.sender != s.holder, "already yours");
        require(newPrice > 0, "price zero");
        require(bytes(newMessage).length <= MAX_MESSAGE, "message too long");

        _settle(seatId);

        uint256 price = s.selfPrice;
        require(msg.value >= price, "send the asking price");

        uint256 newEscrow = msg.value - price;
        require(newEscrow >= taxFor(newPrice, MIN_COVER), "escrow below a week of tax");

        address previous = s.holder;
        uint256 refund = s.escrow;

        // The outgoing holder is credited, never pushed. Their escrow moves
        // from the seat to their credit, so `lockedTotal` only grows by what
        // the buyer just sent.
        if (price + refund > 0) {
            _credits[previous] += price + refund;
            emit Credited(previous, price + refund);
        }
        lockedTotal += msg.value;

        s.holder = msg.sender;
        s.selfPrice = newPrice;
        s.escrow = newEscrow;
        s.lastTaxAt = uint64(block.timestamp);
        s.message = newMessage;
        unchecked {
            s.transfers += 1;
        }
        _seatsHeld[msg.sender].push(seatId);

        emit SeatBought(seatId, previous, msg.sender, price, newPrice);
    }

    /// @notice Re-assess your own seat. Tax is settled at the old price first.
    function setPrice(uint256 seatId, uint256 newPrice) external {
        Seat storage s = _seat(seatId);
        require(s.holder == msg.sender, "not the holder");
        require(newPrice > 0, "price zero");
        _settle(seatId);
        require(s.escrow >= taxFor(newPrice, MIN_COVER), "escrow below a week of tax");
        s.selfPrice = newPrice;
        emit PriceSet(seatId, msg.sender, newPrice);
    }

    /// @notice Add to a seat's tax escrow. Anyone may do this for any seat.
    function depositEscrow(uint256 seatId) external payable {
        Seat storage s = _seat(seatId);
        require(msg.value > 0, "nothing sent");
        _settle(seatId);
        s.escrow += msg.value;
        lockedTotal += msg.value;
        emit EscrowDeposited(seatId, msg.sender, msg.value, s.escrow);
    }

    function updateMessage(uint256 seatId, string calldata message) external {
        Seat storage s = _seat(seatId);
        require(s.holder == msg.sender, "not the holder");
        require(bytes(message).length <= MAX_MESSAGE, "message too long");
        _settle(seatId);
        s.message = message;
        emit MessageUpdated(seatId, message);
    }

    /// @notice Bring a seat's tax up to date. Anyone may call this.
    function collectTax(uint256 seatId) external {
        _seat(seatId);
        _settle(seatId);
    }

    // ------------------------------------------------------------ payouts

    /// @dev Allowed while paused. Credited proceeds are never held hostage.
    function withdraw() external nonReentrant {
        uint256 amount = _credits[msg.sender];
        require(amount > 0, "nothing to withdraw");
        _credits[msg.sender] = 0;
        lockedTotal -= amount;
        emit Withdrawn(msg.sender, amount);
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // --------------------------------------------------------------- views

    /// @notice Tax on `price` over `seconds_`, at the current rate.
    function taxFor(uint256 price, uint64 seconds_) public view returns (uint256) {
        return (price * taxRateBps * seconds_) / (10_000 * uint256(YEAR));
    }

    /// @notice Tax accrued on a seat since it was last settled.
    function taxOwed(uint256 seatId) public view returns (uint256) {
        Seat storage s = _seat(seatId);
        uint64 elapsed = uint64(block.timestamp) - s.lastTaxAt;
        uint256 owed = taxFor(s.selfPrice, elapsed);
        return owed > s.escrow ? s.escrow : owed;
    }

    /// @notice Seconds of tax the escrow still covers. Max value when the seat is foreclosed.
    function coverageSeconds(uint256 seatId) external view returns (uint256) {
        Seat storage s = _seat(seatId);
        if (s.selfPrice == 0 || taxRateBps == 0) return type(uint256).max;
        uint256 owed = taxOwed(seatId);
        uint256 left = s.escrow > owed ? s.escrow - owed : 0;
        return (left * 10_000 * uint256(YEAR)) / (s.selfPrice * taxRateBps);
    }

    /// @notice A foreclosed seat is free to take, bar your own escrow.
    function isForeclosed(uint256 seatId) external view returns (bool) {
        Seat storage s = _seat(seatId);
        if (s.selfPrice == 0) return true;
        uint64 elapsed = uint64(block.timestamp) - s.lastTaxAt;
        return taxFor(s.selfPrice, elapsed) >= s.escrow;
    }

    function seatCount() external view returns (uint256) {
        return _seats.length;
    }

    function getSeat(uint256 seatId) external view returns (Seat memory) {
        return _seat(seatId);
    }

    function creditOf(address who) external view returns (uint256) {
        return _credits[who];
    }

    function seatsHeldBy(address who) external view returns (uint256[] memory) {
        return _seatsHeld[who];
    }

    /// @notice Newest-first page of seat ids.
    function getRecent(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _seats.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    // --------------------------------------------------------------- admin

    function setTaxRateBps(uint16 newRate) external onlyOwner {
        require(newRate <= MAX_TAX_BPS, "rate too high");
        taxRateBps = newRate;
        emit TaxRateUpdated(newRate);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`, which is tax already drawn. Escrow
    ///      still sitting on a seat, and credits owed to holders, are untouchable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    /**
     * @dev Draw whatever tax has accrued. If the escrow cannot cover it the
     *      seat forecloses: the escrow is taken in full and the price falls to
     *      zero, which puts the seat up for the taking.
     */
    function _settle(uint256 seatId) private {
        Seat storage s = _seats[seatId];
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs == s.lastTaxAt || s.selfPrice == 0) {
            s.lastTaxAt = nowTs;
            return;
        }

        uint256 owed = taxFor(s.selfPrice, nowTs - s.lastTaxAt);
        s.lastTaxAt = nowTs;

        if (owed >= s.escrow) {
            uint256 taken = s.escrow;
            s.escrow = 0;
            s.selfPrice = 0;
            accumulatedFees += taken;
            lockedTotal -= taken;
            emit TaxCollected(seatId, taken, 0);
            emit Foreclosed(seatId, s.holder);
        } else {
            s.escrow -= owed;
            accumulatedFees += owed;
            lockedTotal -= owed;
            emit TaxCollected(seatId, owed, s.escrow);
        }
    }

    function _seat(uint256 id) private view returns (Seat storage) {
        require(id < _seats.length, "no such seat");
        return _seats[id];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}
