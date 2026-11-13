// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SGLDStaking} from "../src/SGLDStaking.sol";
import {SGLDToken} from "../src/SGLDToken.sol";

contract MockSGLD is ERC20 {
    bool public fee;
    constructor() ERC20("Test Gold", "SGLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(bool enabled) external {
        fee = enabled;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (fee && from != address(0) && to != address(0)) {
            super._update(from, address(0), amount / 100);
            amount -= amount / 100;
        }
        super._update(from, to, amount);
    }
}

contract SGLDStakingTest is Test {
    MockSGLD token;
    SGLDStaking vault;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    address funder = address(0xf00d);
    address pauser = address(0xbabe);
    uint256 start;

    function setUp() public {
        vm.warp(1_800_000_000);
        start = block.timestamp;
        token = new MockSGLD();
        vault = new SGLDStaking(address(token), address(this), funder, pauser);
        vault.unpauseDeposits();
        address[3] memory users = [alice, bob, funder];
        for (uint256 i; i < users.length; ++i) {
            token.mint(users[i], 1000e18);
            vm.prank(users[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function _stake(address owner, uint256 amount, uint256 term) internal returns (uint256 id) {
        vm.prank(owner);
        return vault.stake(amount, term);
    }

    function _epoch(uint256 end) internal returns (uint256 id) {
        vm.prank(funder);
        id = vault.createEpoch(end);
        (,,,,,,, bool finalized) = vault.epochs(id);
        while (!finalized) {
            vault.processEpoch(id, 100);
            (,,,,,,, finalized) = vault.epochs(id);
        }
    }

    function _fund(uint256 id, uint256 amount) internal {
        vm.prank(funder);
        vault.fundEpoch(id, amount);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _net(uint256 gross) internal pure returns (uint256) {
        return gross - Math.mulDiv(gross, 25, 10_000);
    }

    function _redemption(uint256 principal) internal pure returns (uint256) {
        return principal - Math.mulDiv(principal, 50, 10_000);
    }

    function _walletAfterExit(uint256 gross, uint256 yieldPaid) internal pure returns (uint256) {
        return 1000e18 - gross + _redemption(_net(gross)) + yieldPaid;
    }

    function testMintExactlyOneToOneAndSeparateLocks() public {
        _stake(alice, 1e18, 30);
        _stake(alice, 2e18, 90);
        assertEq(vault.balanceOf(alice), _net(3e18));
        assertEq(vault.totalSupply(), _net(3e18));
        assertEq(vault.totalPrincipal(), _net(3e18));
        (,,, uint256 first,) = vault.positions(0);
        (,,, uint256 second,) = vault.positions(1);
        assertEq(first, start + 30 days);
        assertEq(second, start + 90 days);
    }

    function testDeploymentStartsPausedUntilAdminActivation() public {
        SGLDStaking fresh = new SGLDStaking(address(token), address(this), funder, pauser);
        assertTrue(fresh.paused());
        vm.prank(alice);
        token.approve(address(fresh), 1e18);
        vm.prank(alice);
        vm.expectRevert();
        fresh.stake(1e18, 30);
        vm.prank(bob);
        vm.expectRevert();
        fresh.unpauseDeposits();
        fresh.unpauseDeposits();
        vm.prank(alice);
        fresh.stake(1e18, 30);
        assertEq(fresh.balanceOf(alice), 0.9975e18);
    }

    function testMinimumAndTermsAreEnforcedOnchain() public {
        vm.startPrank(alice);
        vm.expectRevert(SGLDStaking.BelowMinimum.selector);
        vault.stake(1e18 - 1, 30);
        vm.expectRevert(SGLDStaking.InvalidTerm.selector);
        vault.stake(1e18, 60);
        vm.stopPrank();
        assertEq(vault.totalSupply(), 0);
    }

    function testFeeQuotesAndTreasuryPayments() public {
        address treasury = vault.FEE_RECIPIENT();
        assertEq(treasury, 0x42f0E74872c77939422f3c6cEb9D62984BaE5b69);
        (uint256 principal, uint256 entryFee) = vault.previewDeposit(100e18);
        assertEq(principal, 99.75e18);
        assertEq(entryFee, 0.25e18);
        _stake(alice, 100e18, 30);
        assertEq(vault.balanceOf(alice), 99.75e18);
        assertEq(token.balanceOf(treasury), 0.25e18);
        assertEq(token.balanceOf(address(vault)), 99.75e18);
        vm.warp(start + 30 days);
        uint256 epoch = _epoch(block.timestamp);
        _fund(epoch, 1e18);
        (uint256 principalPaid, uint256 exitFee) = vault.previewRedemption(principal);
        assertEq(principalPaid, 99.25125e18);
        assertEq(exitFee, 0.49875e18);
        vm.prank(alice);
        vault.withdraw(0, _one(epoch));
        assertEq(token.balanceOf(treasury), 0.74875e18);
        assertEq(token.balanceOf(alice), 1000.25125e18);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.rewardReserve(), 0);
    }

    function testMinimumDepositAndDirectRestakingHaveNoExtraFees() public {
        _stake(alice, 1e18, 30);
        assertEq(vault.balanceOf(alice), 0.9975e18);
        uint256 feeBalance = token.balanceOf(vault.FEE_RECIPIENT());
        vm.warp(start + 30 days);
        vm.prank(alice);
        uint256 id = vault.restake(0, 90);
        assertEq(token.balanceOf(vault.FEE_RECIPIENT()), feeBalance);
        assertEq(vault.balanceOf(alice), 0.9975e18);
        assertEq(vault.totalPrincipal(), 0.9975e18);
        (, uint256 principal,,, bool withdrawn) = vault.positions(id);
        assertEq(principal, 0.9975e18);
        assertFalse(withdrawn);
        assertEq(token.balanceOf(alice), 999e18);
    }

    function testSeparateLateClaimAndCombinedClaimPayIdenticalFees() public {
        _stake(alice, 100e18, 30);
        _stake(bob, 100e18, 30);
        vm.warp(start + 30 days);
        uint256 epoch = _epoch(block.timestamp);
        _fund(epoch, 2e18);
        vm.prank(alice);
        vault.withdraw(0, _one(epoch));
        vm.prank(bob);
        vault.withdraw(1, new uint256[](0));
        uint256 beforeFeeBalance = token.balanceOf(vault.FEE_RECIPIENT());
        vm.prank(bob);
        assertEq(vault.claim(1, _one(epoch)), 1e18);
        assertEq(token.balanceOf(vault.FEE_RECIPIENT()), beforeFeeBalance);
        assertEq(token.balanceOf(alice), token.balanceOf(bob));
        assertEq(token.balanceOf(bob), _walletAfterExit(100e18, 1e18));
    }

    function testGrossApprovalRequiredAndFailedDepositDoesNotPayFee() public {
        vm.startPrank(alice);
        token.approve(address(vault), _net(100e18));
        vm.expectRevert();
        vault.stake(100e18, 30);
        vm.stopPrank();
        assertEq(vault.positionCount(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(token.balanceOf(vault.FEE_RECIPIENT()), 0);
    }

    function testFuzz_FeeQuotesConserveSGLD(uint256 gross) public view {
        (uint256 principal, uint256 entryFee) = vault.previewDeposit(gross);
        assertEq(entryFee, Math.mulDiv(gross, 25, 10_000));
        assertEq(principal + entryFee, gross);
        (uint256 payout, uint256 exitFee) = vault.previewRedemption(principal);
        assertEq(exitFee, Math.mulDiv(principal, 50, 10_000));
        assertEq(payout + exitFee, principal);
    }

    function testNoReceiptTransfersOrDelegatedLockBypass() public {
        _stake(alice, 10e18, 30);
        vm.prank(alice);
        vm.expectRevert(SGLDStaking.NonTransferable.selector);
        vault.transfer(bob, 1e18);
        vm.prank(alice);
        vault.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(SGLDStaking.NonTransferable.selector);
        vault.transferFrom(alice, bob, 1e18);
        assertEq(vault.balanceOf(alice), _net(10e18));
    }

    function testStrictMaturityAndOwnerOnlyExit() public {
        _stake(alice, 10e18, 30);
        vm.warp(start + 30 days - 1);
        vm.prank(alice);
        vm.expectRevert(SGLDStaking.PositionLocked.selector);
        vault.withdraw(0, new uint256[](0));
        vm.warp(start + 30 days);
        vm.prank(bob);
        vm.expectRevert(SGLDStaking.NotPositionOwner.selector);
        vault.withdraw(0, new uint256[](0));
        vm.prank(alice);
        vault.withdraw(0, new uint256[](0));
        assertEq(token.balanceOf(alice), _walletAfterExit(10e18, 0));
        assertEq(vault.totalSupply(), 0);
        vm.prank(alice);
        vm.expectRevert(SGLDStaking.AlreadyWithdrawn.selector);
        vault.withdraw(0, new uint256[](0));
    }

    function testHistoricalWeightsAndYieldPaidWithPrincipal() public {
        _stake(alice, 10e18, 30);
        vm.warp(start + 15 days);
        _stake(bob, 10e18, 30);
        vm.warp(start + 30 days);
        uint256 epoch = _epoch(block.timestamp);
        _fund(epoch, 3e18);
        assertEq(vault.positionWeight(0, epoch), _net(10e18) * 30 days);
        assertEq(vault.positionWeight(1, epoch), _net(10e18) * 15 days);
        vm.prank(alice);
        vault.withdraw(0, _one(epoch));
        assertEq(token.balanceOf(alice), _walletAfterExit(10e18, 2e18));
        assertEq(vault.rewardReserve(), 1e18);
        assertEq(vault.claimable(1, epoch), 0);
        vm.warp(start + 45 days);
        assertEq(vault.claimable(1, epoch), 1e18);
        vm.prank(bob);
        vault.withdraw(1, _one(epoch));
        assertEq(token.balanceOf(bob), _walletAfterExit(10e18, 1e18));
        assertEq(vault.rewardReserve(), 0);
    }

    function testLateFundingAfterExitAndRepeatedFunding() public {
        _stake(alice, 10e18, 30);
        vm.warp(start + 30 days);
        vm.prank(alice);
        vault.withdraw(0, new uint256[](0));
        vm.warp(start + 60 days);
        _stake(bob, 20e18, 90);
        uint256 epoch = _epoch(start + 30 days);
        _fund(epoch, 1e18);
        assertEq(vault.positionWeight(1, epoch), 0);
        vm.prank(alice);
        vault.claim(0, _one(epoch));
        _fund(epoch, 2e18);
        assertEq(vault.claimable(0, epoch), 2e18);
        uint256[] memory duplicates = new uint256[](2);
        vm.prank(alice);
        assertEq(vault.claim(0, duplicates), 2e18);
        assertEq(vault.claimable(0, epoch), 0);
        assertEq(token.balanceOf(alice), _walletAfterExit(10e18, 3e18));
    }

    function testMaturityStopsWeightEvenWithoutWithdrawal() public {
        _stake(alice, 10e18, 30);
        _stake(bob, 10e18, 90);
        vm.warp(start + 90 days);
        uint256 epoch = _epoch(block.timestamp);
        _fund(epoch, 4e18);
        assertEq(vault.claimable(0, epoch), 1e18);
        assertEq(vault.claimable(1, epoch), 3e18);
    }

    function testRestakingStartsNewEligibilityPreservesOldInterest() public {
        _stake(alice, 10e18, 30);
        vm.warp(start + 40 days);
        vm.prank(alice);
        uint256 newId = vault.restake(0, 90);
        assertEq(newId, 1);
        assertEq(vault.balanceOf(alice), _net(10e18));
        assertEq(token.balanceOf(alice), 990e18);
        vm.warp(start + 50 days);
        uint256 epoch = _epoch(block.timestamp);
        assertEq(vault.positionWeight(0, epoch), _net(10e18) * 30 days);
        assertEq(vault.positionWeight(1, epoch), _net(10e18) * 10 days);
        _fund(epoch, 4e18);
        vm.prank(alice);
        assertEq(vault.claim(0, _one(epoch)), 3e18);
        vm.prank(alice);
        vm.expectRevert(SGLDStaking.PositionLocked.selector);
        vault.withdraw(1, new uint256[](0));
    }

    function testDepositPauseDoesNotBlockExitsOrLateClaims() public {
        _stake(alice, 10e18, 30);
        vm.prank(pauser);
        vault.pauseDeposits();
        vm.prank(bob);
        vm.expectRevert();
        vault.stake(1e18, 30);
        vm.warp(start + 30 days);
        uint256 epoch = _epoch(block.timestamp);
        _fund(epoch, 1e18);
        vm.prank(alice);
        vault.withdraw(0, _one(epoch));
        assertEq(token.balanceOf(alice), _walletAfterExit(10e18, 1e18));
    }

    function testFundingRequiresFinalizationAndEligibleWeight() public {
        _stake(alice, 1e18, 30);
        vm.warp(start + 1 days);
        vm.prank(funder);
        uint256 epoch = vault.createEpoch(block.timestamp);
        vm.prank(funder);
        vm.expectRevert(SGLDStaking.EpochNotFinalized.selector);
        vault.fundEpoch(epoch, 1e18);
        vault.processEpoch(epoch, 100);
        vm.prank(bob);
        vm.expectRevert();
        vault.fundEpoch(epoch, 1e18);
        vm.prank(bob);
        vm.expectRevert();
        vault.createEpoch(block.timestamp);
        vm.warp(start + 90 days);
        _epoch(block.timestamp);
        vm.warp(start + 91 days);
        uint256 empty = _epoch(block.timestamp);
        vm.prank(funder);
        vm.expectRevert(SGLDStaking.NoEligibleWeight.selector);
        vault.fundEpoch(empty, 1e18);
    }

    function testEpochsRejectOverlapFutureAndExcessivePeriod() public {
        vm.warp(start + 100 days);
        vm.startPrank(funder);
        vm.expectRevert(SGLDStaking.InvalidEpoch.selector);
        vault.createEpoch(start + 91 days);
        vault.createEpoch(start + 30 days);
        vm.expectRevert(SGLDStaking.InvalidEpoch.selector);
        vault.createEpoch(start + 30 days);
        vm.expectRevert(SGLDStaking.InvalidEpoch.selector);
        vault.createEpoch(block.timestamp + 1);
        vm.stopPrank();
    }

    function testProcessingBoundedAndSnapshotExcludesLaterPositions() public {
        for (uint256 i; i < 101; ++i) {
            _stake(alice, 1e18, 30);
        }
        vm.warp(start + 1 days);
        vm.prank(funder);
        uint256 epoch = vault.createEpoch(block.timestamp);
        _stake(bob, 1e18, 30);
        vm.expectRevert(SGLDStaking.InvalidBatch.selector);
        vault.processEpoch(epoch, 101);
        vault.processEpoch(epoch, 1);
        (,,, uint256 cursor,,,, bool done) = vault.epochs(epoch);
        assertEq(cursor, 1);
        assertFalse(done);
        vault.processEpoch(epoch, 100);
        (,,,, uint256 weight,,, bool finalized) = vault.epochs(epoch);
        assertTrue(finalized);
        assertEq(weight, 101 * _net(1e18) * 1 days);
        assertEq(vault.positionWeight(101, epoch), 0);
    }

    function testUnsolicitedDonationNeverMintsReceiptsOrFundsRewards() public {
        _stake(alice, 10e18, 30);
        token.mint(address(vault), 100e18);
        assertEq(vault.totalSupply(), _net(10e18));
        assertEq(vault.totalPrincipal(), _net(10e18));
        assertEq(vault.rewardReserve(), 0);
        vm.warp(start + 30 days);
        uint256 epoch = _epoch(block.timestamp);
        assertEq(vault.claimable(0, epoch), 0);
        vm.prank(alice);
        vault.withdraw(0, new uint256[](0));
        assertEq(token.balanceOf(address(vault)), 100e18);
    }

    function testPrincipalBoundAndFullPrecisionLargeReward() public {
        uint256 cap = vault.MAX_PRINCIPAL();
        uint256 gross = Math.mulDiv(cap, 10_000, 9975);
        token.mint(alice, gross);
        _stake(alice, gross, 90);
        assertEq(vault.totalPrincipal(), cap);
        vm.prank(bob);
        vm.expectRevert(SGLDStaking.PrincipalLimit.selector);
        vault.stake(1e18, 30);
        vm.warp(start + 90 days);
        uint256 epoch = _epoch(block.timestamp);
        token.mint(funder, cap);
        _fund(epoch, cap);
        assertEq(vault.claimable(0, epoch), cap);
        vm.prank(alice);
        vault.withdraw(0, _one(epoch));
        assertEq(token.balanceOf(alice), 1000e18 + _redemption(cap) + cap);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.rewardReserve(), 0);
    }

    function testClaimBatchLimitDoesNotPreventPrincipalExit() public {
        _stake(alice, 1e18, 30);
        vm.warp(start + 30 days);
        vm.prank(alice);
        vm.expectRevert(SGLDStaking.InvalidBatch.selector);
        vault.withdraw(0, new uint256[](33));
        assertEq(vault.totalPrincipal(), _net(1e18));
        vm.prank(alice);
        vault.withdraw(0, new uint256[](0));
        assertEq(vault.totalPrincipal(), 0);
    }

    function testFeeOnTransferDepositAndFundingRevertAtomically() public {
        token.setFee(true);
        vm.prank(alice);
        vm.expectRevert(SGLDStaking.UnsupportedTransfer.selector);
        vault.stake(10e18, 30);
        assertEq(vault.positionCount(), 0);
        token.setFee(false);
        _stake(alice, 10e18, 30);
        vm.warp(start + 30 days);
        uint256 epoch = _epoch(block.timestamp);
        token.setFee(true);
        vm.prank(funder);
        vm.expectRevert(SGLDStaking.UnsupportedTransfer.selector);
        vault.fundEpoch(epoch, 1e18);
        assertEq(vault.rewardReserve(), 0);
        vm.prank(alice);
        vm.expectRevert(SGLDStaking.UnsupportedTransfer.selector);
        vault.withdraw(0, new uint256[](0));
        assertEq(vault.totalPrincipal(), _net(10e18));
    }

    function testReentrantTokenCannotEnterStakeDuringTransfer() public {
        ReentrantSGLD attackerToken = new ReentrantSGLD();
        SGLDStaking guarded = new SGLDStaking(address(attackerToken), address(this), funder, pauser);
        guarded.unpauseDeposits();
        attackerToken.setTarget(address(guarded));
        attackerToken.mint(alice, 1e18);
        vm.startPrank(alice);
        attackerToken.approve(address(guarded), 1e18);
        guarded.stake(1e18, 30);
        vm.stopPrank();
        assertTrue(attackerToken.attempted());
        assertEq(attackerToken.revertSelector(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(guarded.totalSupply(), _net(1e18));
        assertEq(guarded.positionCount(), 1);
    }

    function testExistingSGLDProxyIntegrationAndUnderlyingPause() public {
        SGLDToken implementation = new SGLDToken();
        SGLDToken real = SGLDToken(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(SGLDToken.initialize, (address(this)))))
        );
        real.grantRole(real.MINTER_ROLE(), address(this));
        real.mint(alice, 10e18);
        SGLDStaking liveLike = new SGLDStaking(address(real), address(this), funder, pauser);
        liveLike.unpauseDeposits();
        vm.startPrank(alice);
        real.approve(address(liveLike), 10e18);
        liveLike.stake(10e18, 30);
        vm.stopPrank();
        vm.warp(start + 30 days);
        real.pause();
        vm.prank(alice);
        vm.expectRevert();
        liveLike.withdraw(0, new uint256[](0));
        assertEq(liveLike.totalPrincipal(), _net(10e18));
        real.unpause();
        vm.prank(alice);
        liveLike.withdraw(0, new uint256[](0));
        assertEq(real.balanceOf(alice), _redemption(_net(10e18)));
    }

    function testFuzz_TimeWeightedAllocationConservesFunding(
        uint96 rawA,
        uint96 rawB,
        uint32 rawDelay,
        uint96 rawReward
    ) public {
        uint256 a = bound(rawA, 1e18, 100e18);
        uint256 b = bound(rawB, 1e18, 100e18);
        uint256 delay = bound(rawDelay, 1, 29 days);
        uint256 reward = bound(rawReward, 1, 100e18);
        _stake(alice, a, 30);
        vm.warp(start + delay);
        _stake(bob, b, 90);
        vm.warp(start + 30 days);
        uint256 epoch = _epoch(block.timestamp);
        _fund(epoch, reward);
        vm.warp(start + 120 days);
        uint256 wa = _net(a) * 30 days;
        uint256 wb = _net(b) * (30 days - delay);
        uint256 expectedA = Math.mulDiv(reward, wa, wa + wb);
        uint256 expectedB = Math.mulDiv(reward, wb, wa + wb);
        assertEq(vault.claimable(0, epoch), expectedA);
        assertEq(vault.claimable(1, epoch), expectedB);
        vm.prank(alice);
        vault.withdraw(0, _one(epoch));
        vm.prank(bob);
        vault.withdraw(1, _one(epoch));
        assertEq(vault.rewardReserve(), reward - expectedA - expectedB);
        assertLe(vault.rewardReserve(), 1);
        assertEq(vault.totalSupply(), 0);
        assertEq(token.balanceOf(address(vault)), vault.rewardReserve());
    }
}

contract ReentrantSGLD is ERC20 {
    address public target;
    bool public attempted;
    bytes4 public revertSelector;
    constructor() ERC20("Reentrant Test", "SGLD") {}

    function setTarget(address value) external {
        target = value;
    }

    function mint(address owner, uint256 value) external {
        _mint(owner, value);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        attempted = true;
        (bool ok, bytes memory result) = target.call(abi.encodeWithSignature("stake(uint256,uint256)", 1e18, 30));
        require(!ok, "Reentry unexpectedly succeeded");
        if (result.length >= 4) {
            bytes4 selector;
            assembly { selector := mload(add(result, 32)) }
            revertSelector = selector;
        }
        return super.transferFrom(from, to, amount);
    }
}

contract StakingHandler is Test {
    MockSGLD public token;
    SGLDStaking public vault;
    uint256 public expectedFees;

    constructor() {
        token = new MockSGLD();
        vault = new SGLDStaking(address(token), address(this), address(this), address(this));
        vault.unpauseDeposits();
        token.approve(address(vault), type(uint256).max);
    }

    function deposit(uint96 seed, bool longTerm) external {
        if (vault.positionCount() >= 64) return;
        uint256 amount = bound(seed, 1e18, 100e18);
        token.mint(address(this), amount);
        vault.stake(amount, longTerm ? 90 : 30);
        expectedFees += Math.mulDiv(amount, 25, 10_000);
    }

    function advance(uint32 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 10 days));
    }

    function settle(uint96 seed) external {
        uint256 end = Math.min(block.timestamp, vault.lastEpochEnd() + 90 days);
        if (end <= vault.lastEpochEnd()) return;
        uint256 id = vault.createEpoch(end);
        (,,,,,,, bool finalized) = vault.epochs(id);
        if (!finalized) vault.processEpoch(id, 100);
        (,,,, uint256 weight,,,) = vault.epochs(id);
        if (weight == 0) return;
        uint256 amount = bound(seed, 1, 100e18);
        token.mint(address(this), amount);
        vault.fundEpoch(id, amount);
    }

    function exit(uint256 seed) external {
        uint256 count = vault.positionCount();
        if (count == 0) return;
        uint256 id = seed % count;
        (, uint256 principal,, uint256 maturity, bool withdrawn) = vault.positions(id);
        if (withdrawn || block.timestamp < maturity) return;
        vault.withdraw(id, new uint256[](0));
        expectedFees += Math.mulDiv(principal, 50, 10_000);
    }

    function roll(uint256 seed, bool longTerm) external {
        uint256 count = vault.positionCount();
        if (count == 0 || count >= 64) return;
        uint256 id = seed % count;
        (,,, uint256 maturity, bool withdrawn) = vault.positions(id);
        if (withdrawn || block.timestamp < maturity) return;
        vault.restake(id, longTerm ? 90 : 30);
    }

    function collect(uint256 posSeed, uint256 epochSeed) external {
        if (vault.positionCount() == 0 || vault.epochCount() == 0) return;
        uint256 id = posSeed % vault.positionCount();
        (,,, uint256 maturity,) = vault.positions(id);
        if (block.timestamp < maturity) return;
        uint256[] memory ids = new uint256[](1);
        ids[0] = epochSeed % vault.epochCount();
        vault.claim(id, ids);
    }
}

contract SGLDStakingInvariantTest is StdInvariant, Test {
    StakingHandler handler;

    function setUp() public {
        handler = new StakingHandler();
        targetContract(address(handler));
    }

    function invariant_ReceiptsAndFundedLiabilitiesRemainBacked() public view {
        SGLDStaking vault = handler.vault();
        assertEq(vault.totalSupply(), vault.totalPrincipal());
        assertEq(vault.balanceOf(address(handler)), vault.totalPrincipal());
        assertGe(handler.token().balanceOf(address(vault)), vault.totalPrincipal() + vault.rewardReserve());
        uint256 outstanding;
        for (uint256 i; i < vault.positionCount(); ++i) {
            (, uint256 principal,,, bool withdrawn) = vault.positions(i);
            if (!withdrawn) outstanding += principal;
        }
        assertEq(vault.totalPrincipal(), outstanding);
        uint256 unclaimed;
        for (uint256 i; i < vault.epochCount(); ++i) {
            (,,,,, uint256 funded, uint256 claimed,) = vault.epochs(i);
            assertLe(claimed, funded);
            unclaimed += funded - claimed;
        }
        assertEq(vault.rewardReserve(), unclaimed);
        assertEq(handler.token().balanceOf(vault.FEE_RECIPIENT()), handler.expectedFees());
    }
}

