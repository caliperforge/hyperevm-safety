// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {HyperCoreOracleGuard} from "hyperevm-safety/src/HyperCoreOracleGuard.sol";
import {ChainlinkCompatAdapter} from "hyperevm-safety/src/ChainlinkCompatAdapter.sol";
import {HyperCorePrecompileAddresses} from "hyperevm-safety/src/interfaces/IHyperCorePrecompiles.sol";
import {MockPrecompiles} from "hyperevm-safety/invariants/mocks/MockPrecompiles.sol";

import {MinimalLendingMarket, IMinimalERC20} from "../src/MinimalLendingMarket.sol";

/// @dev Trivial 18-decimal ERC20 used purely by this smoke test. Kept inline
///      so the example has zero external dependencies beyond `forge-std` and
///      the parent library — a contributor cloning the example to use as a
///      starter sees no surprise imports.
contract MockToken is IMinimalERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @title Smoke — deposit → price update → withdraw round-trip.
/// @notice Spec §T-4 acceptance: this file is the smoke test the ticket
///         requires. It exercises the full happy-path lifecycle of the
///         minimal-lending-market: a user deposits collateral, the HyperCore
///         mark price updates between blocks, the user withdraws, and the
///         pro-rata redemption returns their full deposit (single-user
///         market — no dilution path).
///
///         The test ALSO exercises the staleness gate negatively: a separate
///         test holds L1 block frozen, advances EVM blocks past the bound,
///         and asserts the deposit reverts. That's the integration-level
///         proof that the library's D-1 invariant fires on the example's
///         consume path, not just on the library's own self-tests.
contract SmokeTest is Test {
    // -------------------------------------------------------------------------
    // Configuration — matches the Properties.sol bundle conventions so the
    // example's wire-up reads identically to a contributor reading the
    // library's own M1 invariant tests.
    // -------------------------------------------------------------------------

    uint64 internal constant MAX_STALENESS_BLOCKS = 5;
    uint8 internal constant WINDOW_SIZE = 4;
    uint16 internal constant MAX_DEVIATION_BPS = 500; // 5%

    uint32 internal constant ASSET = 1;
    uint64 internal constant SEED_PRICE = 100_00_000_000; // 100.00 in 8-decimal
    uint64 internal constant NEW_PRICE = 150_00_000_000; // 150.00 in 8-decimal

    uint64 internal constant GENESIS_TS = 1_700_000_000;
    uint64 internal constant BLOCK_MS = 70;
    uint64 internal constant INITIAL_L1_BLOCK = 100_000;
    // GENESIS_TS + INITIAL_L1_BLOCK * BLOCK_MS / 1000 = 1_700_007_000.
    uint256 internal constant INITIAL_ADAPTER_UPDATED_AT = 1_700_007_000;
    // 1 hour of seconds-staleness allowance for the adapter.
    uint64 internal constant MAX_ADAPTER_AGE_SEC = 3600;

    uint8 internal constant COLLATERAL_DECIMALS = 18;
    uint256 internal constant DEPOSIT_AMOUNT = 100 ether; // 100 collateral tokens

    address internal user = address(0xA11CE);

    MockToken internal token;
    HyperCoreOracleGuard internal guard;
    ChainlinkCompatAdapter internal priceFeed;
    MinimalLendingMarket internal market;

    function setUp() public {
        // Anchor block + timestamp to a frame the adapter's `updatedAt`
        // computation (`GENESIS_TS + L1_block * BLOCK_MS / 1000`) sits inside.
        // We warp `block.timestamp` to exactly that updatedAt so the
        // seconds-bounded freshness gate starts at zero age.
        vm.roll(INITIAL_L1_BLOCK);
        vm.warp(INITIAL_ADAPTER_UPDATED_AT);

        // Wire the precompile mocks BEFORE deploying the consuming contracts,
        // because constructors don't call them — but `deposit()` does, and the
        // first deposit must see a valid mark/L1 block on day one.
        MockPrecompiles.setMark(ASSET, SEED_PRICE);
        MockPrecompiles.setL1BlockNumber(INITIAL_L1_BLOCK);

        token = new MockToken();
        guard = new HyperCoreOracleGuard(MAX_STALENESS_BLOCKS, WINDOW_SIZE, MAX_DEVIATION_BPS);
        priceFeed = new ChainlinkCompatAdapter(
            HyperCorePrecompileAddresses.MARK,
            ASSET,
            8, // 8-decimal answer, matches HyperCore's native precision
            GENESIS_TS,
            BLOCK_MS,
            "ASSET/USD mark"
        );

        market = new MinimalLendingMarket(
            IMinimalERC20(address(token)),
            COLLATERAL_DECIMALS,
            guard,
            priceFeed,
            ASSET,
            MAX_ADAPTER_AGE_SEC
        );

        // Fund the user. 1000 tokens is comfortably above the test's needs;
        // leftover balance after withdraw is asserted to confirm the user
        // can't accidentally receive more than they deposited (single-user
        // market — pro-rata == identity).
        token.mint(user, 1000 ether);
        vm.prank(user);
        token.approve(address(market), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // The headline acceptance test: deposit → price update → withdraw round-trip.
    // -------------------------------------------------------------------------

    function test_smoke_deposit_priceUpdate_withdraw_roundTrip() public {
        // ---- (1) Deposit at price = $100 ----
        uint256 userBalBefore = token.balanceOf(user);

        vm.prank(user);
        uint256 mintedShares = market.deposit(DEPOSIT_AMOUNT);

        assertEq(mintedShares, DEPOSIT_AMOUNT, "bootstrap mints 1:1");
        assertEq(market.sharesOf(user), mintedShares, "user share balance");
        assertEq(market.totalShares(), mintedShares, "total shares");
        assertEq(token.balanceOf(address(market)), DEPOSIT_AMOUNT, "market collateral balance");
        assertEq(token.balanceOf(user), userBalBefore - DEPOSIT_AMOUNT, "user spent collateral");

        // Quote-surface sanity at price = $100.
        // pricePerShare = (bal * price) / (totalShares * 10**18)
        //              = (100e18 * 100_00000000) / (100e18 * 10**18)
        //              = 100_00000000 / 10**18 = 0 (integer truncation: 100 collateral × $100 ÷ shares-with-18-decimals
        // is sub-unit at 8-decimal precision when shares share the collateral's 18-decimal scale).
        // The valueOf() helper avoids the per-share truncation by computing on the user's full holding.
        uint256 valueAtP1 = market.valueOf(user);
        // value = (sharesOf * bal / totalShares) * price / 10**collateralDecimals
        //       = (1 * 100e18) * 100_00000000 / 10**18 = 10000_00000000 = $10_000.00
        assertEq(valueAtP1, 10000_00000000, "value at price=$100");

        // ---- (2) Price update from $100 → $150, time advances 60 seconds ----
        // Advance EVM and HyperCore L1 in lockstep so the staleness gates stay
        // happy; bump block.timestamp by 60s + bump the L1 block by 60s/0.07s
        // worth so the adapter's `updatedAt` tracks `block.timestamp` exactly.
        vm.warp(block.timestamp + 60);
        uint64 newL1 = INITIAL_L1_BLOCK + uint64((60 * 1000) / BLOCK_MS); // +857 blocks
        vm.roll(block.number + uint64((60 * 1000) / BLOCK_MS));
        MockPrecompiles.setL1BlockNumber(newL1);
        MockPrecompiles.setMark(ASSET, NEW_PRICE);

        // The price change shows up immediately in the view surface — the
        // collateral didn't move, but each share's USD value is now 1.5×.
        uint256 valueAtP2 = market.valueOf(user);
        // value = 100e18 * 150_00000000 / 1e18 = 15000_00000000 = $15_000.00
        assertEq(valueAtP2, 15000_00000000, "value at price=$150");

        // ---- (3) Withdraw all shares ----
        uint256 userBalBeforeWithdraw = token.balanceOf(user);

        vm.prank(user);
        uint256 returned = market.withdraw(mintedShares);

        // Pro-rata redemption in a single-user market returns the full
        // collateral the user deposited. The USD value of that collateral
        // is higher (price went up), but the underlying token amount is
        // unchanged — the standard ERC4626 vault behaviour for one asset.
        assertEq(returned, DEPOSIT_AMOUNT, "single-user pro-rata returns full deposit");
        assertEq(market.sharesOf(user), 0, "shares burned");
        assertEq(market.totalShares(), 0, "total shares zeroed");
        assertEq(token.balanceOf(address(market)), 0, "market drained");
        assertEq(token.balanceOf(user), userBalBeforeWithdraw + DEPOSIT_AMOUNT, "user round-tripped collateral");
    }

    // -------------------------------------------------------------------------
    // Staleness-gate integration check: the library's D-1 fires through the
    // market's deposit path when the HyperCore L1 block freezes.
    // -------------------------------------------------------------------------

    function test_smoke_staleHyperCoreL1Block_revertsDeposit() public {
        // Hold L1 block fixed; advance EVM blocks past the staleness bound.
        // Per HyperCoreOracleGuard: revert Stale() when
        //   evmBlock > l1Block AND evmBlock - l1Block > maxStalenessBlocks.
        vm.roll(block.number + MAX_STALENESS_BLOCKS + 1);
        // L1 block stays at INITIAL_L1_BLOCK (the freeze).

        vm.prank(user);
        vm.expectRevert(); // Stale(currentL1Block, readAtL1Block, maxStalenessBlocks)
        market.deposit(DEPOSIT_AMOUNT);
    }

    // -------------------------------------------------------------------------
    // Adapter-layer freshness check: independent of the guard, the seconds-bounded
    // gate against the adapter's `updatedAt` also catches a HyperCore halt.
    // -------------------------------------------------------------------------

    function test_smoke_adapterUpdatedAtTooOld_revertsDeposit() public {
        // Advance block.timestamp past the adapter age bound WITHOUT advancing
        // the HyperCore L1 block — the adapter's updatedAt stays at the
        // initial publish-block timestamp, age grows, and the market's
        // AdapterStale check fires.
        // BUT: don't advance block.number too — that would trip the guard's
        // block-staleness check first (which is also valid, but we want to
        // isolate the seconds-bounded leg). Keep block.number where it is.
        vm.warp(block.timestamp + MAX_ADAPTER_AGE_SEC + 1);
        // Re-set mocks (warp/roll don't invalidate mockCall but we re-register
        // to be explicit about the state under test).
        MockPrecompiles.setL1BlockNumber(INITIAL_L1_BLOCK);
        MockPrecompiles.setMark(ASSET, SEED_PRICE);

        vm.prank(user);
        vm.expectRevert(); // AdapterStale(ageSec, maxAdapterAgeSec)
        market.deposit(DEPOSIT_AMOUNT);
    }
}
