# AgoraSeat

Self-assessed seats on BOT Chain, held under a continuous tax.

A seat is a named position — a title, a slot, a spot on a wall — that one
address holds at a time. The holder names their **own** price and pays a running
tax on that number. Anyone may buy the seat at the holder's own price, at any
moment, without asking.

That pairing is the whole mechanism. Price it low and somebody takes it from you
cheaply. Price it high and the tax bleeds you. The honest valuation is the only
comfortable one, and nobody has to referee it.

## Foreclosure is the only penalty

Tax is drawn from a prepaid escrow, which must always cover at least a week at
the current price. Let it run dry and the seat forecloses: its price drops to
zero and the next person takes it for the cost of their own escrow. No court,
no appeal, no arrears carried forward — a buyer's tax clock starts clean
because `buySeat` settles the outgoing holder first.

| Call | Who | What it does |
|---|---|---|
| `createSeat(title, price, message)` | anyone | Escrow must cover a week of tax |
| `buySeat(id, newPrice, newMessage)` | anyone but the holder | Send the asking price plus your own escrow |
| `setPrice(id, newPrice)` | holder | Settles tax at the old price first |
| `depositEscrow(id)` | **anyone** | Top up any seat's escrow |
| `updateMessage(id, message)` | holder | 140 characters |
| `collectTax(id)` | **anyone** | Brings a seat's tax up to date, and forecloses it if dry |
| `withdraw()` | anyone owed | Pull-based. **Works while paused** |

Proceeds are credited, not pushed — a holder whose address refuses payment
cannot wedge the seat shut for everyone else. `withdrawFees` is bounded by tax
already drawn, so escrow sitting on a seat and credits owed to holders are
untouchable.

Tax rate defaults to 10% a year, capped at 50%.

## Build and deploy

```bash
npm install
npx hardhat test          # 16 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Editorial / broadsheet**: a
newspaper masthead with double rules, a dateline, a leader with a drop cap, and
the seats set as classified entries flowing down three columns. Stark black on
newsprint with one ink of red; the escrow bar turning red is the warning that a
seat is about to be free to take.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.
