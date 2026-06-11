// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {HyperCoreOracleGuard} from "hyperevm-safety/src/HyperCoreOracleGuard.sol";
import {MockPrecompiles} from "hyperevm-safety/invariants/mocks/MockPrecompiles.sol";

import {JellyLendingMarket, IMinimalERC20} from "../src/JellyLendingMarket.sol";

/// @dev 18-decimal token mock. Inline so the incident sub-project pulls zero
///      deps beyond `forge-std` + the parent `hyperevm-safety`. Mirrors the
///      pattern in `examples/minimal-lending-market/tests/Smoke.t.sol`.
contract MockToken is IMinimalERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @title JellyMarkSwingTest — same-source twin scenario for incidents/01-jelly-2025-03.
/// @notice One headline test reproduces the JELLY-style mark-swing attack
///         against the same `JellyLendingMarket` source in both clean and
///         planted legs:
///
///           1. Set up a borrower in a comfortably solvent position at the
///              honest mark ($100/token, 100 tokens collateral, $5k debt
///              against a 50% LTV cap → health 200%).
///           2. Warm the guard's TWAP window at the honest mark (consequence
///              of the clean leg's deviation-bounded read; harmless extra
///              storage in the planted leg).
///           3. An attacker swings the perp mark from $100 → $20 (an 80%
///              drop, far outside the guard's 5% deviation bound).
///           4. A liquidator attempts to seize the borrower's collateral.
///
///         **Clean leg expected outcome:** `liquidate()` calls
///         `_readGuardedMark()` → `readMarkWithDeviationBound()`, which
///         sees the manipulated sample, computes 80% deviation against the
///         warmed TWAP, and reverts `Deviation()` before the liquidation
///         engages. The borrower keeps their position; no
///         `INVARIANT VIOLATED` marker reaches stdout; test passes.
///
///         **Planted leg expected outcome:** `liquidate()` calls
///         `_readGuardedMark()` → `readMark()` (the deviation-unguarded
///         read swapped in by the planted hunk). The manipulated mark
///         flows through; the market computes a 40% health factor against
///         the manipulated mark, finds the borrower under the 80%
///         threshold, and seizes their collateral. But at the honest
///         mark the borrower's health was 200% — well above the threshold.
///         That is `LiquidationSoundness` violated: a liquidation
///         succeeded against a borrower who was solvent at the honest
///         price. The test fires `INVARIANT VIOLATED LiquidationSoundness`
///         on stdout and reverts.
///
/// @dev The CI gate (`.github/workflows/ci.yml` jobs
///      `incident-01-jelly-{clean-passes,planted-fires}`) reads `forge test`
///      stdout for `INVARIANT VIOLATED` and asserts:
///        clean → exit 0, no marker;
///        planted → exit non-zero, marker present.
contract JellyMarkSwingTest is Test {
    // -------------------------------------------------------------------------
    // Constants — mirror the convention used in
    // `invariants/OracleDeviation.t.sol` so a contributor reading both files
    // recognises the same shape.
    // -------------------------------------------------------------------------

    // Guard parameters.
    uint64 internal constant MAX_STALENESS_BLOCKS = 100;
    uint8 internal constant WINDOW_SIZE = 4;
    uint16 internal constant MAX_DEVIATION_BPS = 500; // 5%

    // Market parameters.
    uint32 internal constant ASSET = 1;
    uint8 internal constant COLLATERAL_DECIMALS = 18;
    uint16 internal constant MAX_LTV_BPS = 5000; // 50%
    uint16 internal constant LIQ_THRESHOLD_BPS = 8000; // 80%

    // Prices — 8-decimal precision matches HyperCore's native mark answer.
    uint64 internal constant SEED_PRICE = 100_00_000_000; // $100.00 (honest)
    uint64 internal constant MANIPULATED_PRICE = 20_00_000_000; // $20.00 (post-swing)

    // Block + timestamp anchors.
    uint64 internal constant INITIAL_L1_BLOCK = 1_000_000;

    // Position sizes.
    uint256 internal constant COLLATERAL_AMOUNT = 100 ether; // 100 tokens
    uint256 internal constant DEBT_USD = 5_000_00_000_000; // $5,000.00 (8-decimal scale)

    // -------------------------------------------------------------------------
    // Test fixtures
    // -------------------------------------------------------------------------

    address internal borrower = address(0xBEEF);
    address internal liquidator = address(0xCAFE);

    MockToken internal token;
    HyperCoreOracleGuard internal guard;
    JellyLendingMarket internal market;

    function setUp() public {
        // Anchor block.number alongside the HyperCore L1 block so the guard's
        // staleness check is satisfied on every read. Time is irrelevant for
        // this incident (mark manipulation, not staleness) but vm.warp keeps
        // the harness consistent with `examples/minimal-lending-market`.
        vm.roll(INITIAL_L1_BLOCK);
        MockPrecompiles.setL1BlockNumber(INITIAL_L1_BLOCK);
        MockPrecompiles.setMark(ASSET, SEED_PRICE);

        token = new MockToken();
        guard = new HyperCoreOracleGuard(MAX_STALENESS_BLOCKS, WINDOW_SIZE, MAX_DEVIATION_BPS);
        market = new JellyLendingMarket(
            IMinimalERC20(address(token)),
            COLLATERAL_DECIMALS,
            guard,
            ASSET,
            MAX_LTV_BPS,
            LIQ_THRESHOLD_BPS
        );

        // Warm the guard's TWAP window at the honest seed price. The clean
        // leg's `_readGuardedMark` uses `readMarkWithDeviationBound`, which
        // needs the window warm so the deviation check engages at attack time.
        // The planted leg's `_readGuardedMark` uses `readMark` and never
        // touches the ring — these reads are a no-op for the bug class but
        // keep the test file byte-identical between legs.
        for (uint8 i = 0; i < WINDOW_SIZE; i++) {
            guard.readMarkWithDeviationBound(ASSET);
        }

        // Fund the borrower and stage their position.
        token.mint(borrower, COLLATERAL_AMOUNT);
        vm.startPrank(borrower);
        token.approve(address(market), type(uint256).max);
        market.deposit(COLLATERAL_AMOUNT);
        market.borrow(DEBT_USD);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Sanity: at the honest price the borrower IS solvent. This anchors the
    // LiquidationSoundness assertion below — `liquidated && honestHealth >=
    // threshold` is only a violation if `honestHealth >= threshold` holds in
    // the fixture state.
    // -------------------------------------------------------------------------

    function test_sanity_borrowerSolventAtHonestPrice() public view {
        uint256 honestHealth = market.healthBpsAtPrice(borrower, SEED_PRICE);
        // 100 tokens * $100 = $10k collateral; $5k debt → health = 200% = 20000bps.
        assertEq(honestHealth, 20_000, "borrower should be at 200% health at honest price");
        assertGt(honestHealth, LIQ_THRESHOLD_BPS, "honest health > threshold");
    }

    // -------------------------------------------------------------------------
    // Headline: the JELLY mark-swing scenario, identical in both legs.
    // -------------------------------------------------------------------------

    function test_jellyMarkSwing_LiquidationSoundness_holds() public {
        // Snapshot the borrower's honest-price health BEFORE attempting the
        // liquidation. After a successful liquidation `debtOf` is cleared and
        // `healthBpsAtPrice` would return `type(uint256).max` — misleading
        // for the diagnostic, even if the inequality still fires correctly.
        uint256 honestHealthAtAttackTime = market.healthBpsAtPrice(borrower, SEED_PRICE);

        // Attacker swings the mark — replace the precompile response with the
        // manipulated value. (In a real attack the HyperCore mark moves
        // because of attacker order-book activity; the mock substitutes for
        // that on-chain effect.)
        MockPrecompiles.setMark(ASSET, MANIPULATED_PRICE);

        // Attempt the liquidation. Three branches matter for the property:
        //   - reverts (any reason): the gate did its job — `liquidated` stays
        //     false; the clean leg lands here.
        //   - succeeds & borrower was solvent at honest price: invariant
        //     violated — the planted leg lands here.
        //   - succeeds & borrower was insolvent at honest price: legitimate
        //     liquidation; would not fire (not the case in this fixture).
        bool liquidated;
        vm.prank(liquidator);
        try market.liquidate(borrower) {
            liquidated = true;
        } catch {
            liquidated = false;
        }

        // The invariant: a liquidation may succeed only if the borrower was
        // genuinely under the threshold at the honest price. Otherwise the
        // liquidation engaged on a price that doesn't reflect honest market
        // state — the JELLY bug class.
        if (liquidated && honestHealthAtAttackTime >= LIQ_THRESHOLD_BPS) {
            // CI's stdout-grep target (.github/workflows/ci.yml job
            // `incident-01-jelly-planted-fires`). console2.log writes the
            // marker to stdout; the revert reason carries it again for
            // double coverage in the test summary.
            console2.log("INVARIANT VIOLATED LiquidationSoundness");
            console2.log("  honest_health_bps =", honestHealthAtAttackTime);
            console2.log("  liquidation_threshold_bps =", LIQ_THRESHOLD_BPS);
            console2.log("  manipulated_mark =", MANIPULATED_PRICE);
            console2.log("  honest_mark =", SEED_PRICE);
            revert("INVARIANT VIOLATED LiquidationSoundness");
        }

        // Clean-leg post-condition: the deviation gate must have blocked the
        // liquidation. Lands here only when `liquidated == false`.
        assertFalse(liquidated, "clean leg: deviation gate must block liquidation on manipulated mark");
    }
}
