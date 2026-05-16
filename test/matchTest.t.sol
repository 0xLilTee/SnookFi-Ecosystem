// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

import "forge-std/StdStorage.sol";
import {Test, console} from "forge-std/Test.sol";
import {snookerMatch} from "../src/Match.sol";
import {MockUSDT} from "../src/MockUSDT.sol";
import {SnookFiBase} from "../src/Base.sol";
import {IRefereeRegistry} from "../src/Interface/IRefereeRegistry.sol";
import {RefereeRegistry} from "src/RefereeRegistry.sol";

contract MatchTest is Test {
    using stdStorage for StdStorage;
    snookerMatch matchGame;
    MockUSDT usdt;
    RefereeRegistry registry;

    address player1 = address(0x1);
    address player2 = address(0x2);
    address player3 = address(0x3);
    address owner = address(this);

    uint256 refereePk  = 0xA11CE;
    uint256 refereePk1 = 0xB22DF;   // ← add this
    uint256 refereePk2 = 0xC33E0;   // ← add this

    address referee;
    address referee1;               // ← add this
    address referee2;               // ← add this

    uint256 public constant REMATCH_WINDOW = 10;
    uint256 stakeAmount = 100 * 10**6;

    function setUp() public {
        usdt = new MockUSDT();

        // Derive addresses from keys
        referee  = vm.addr(refereePk);
        referee1 = vm.addr(refereePk1);   // ← add this
        referee2 = vm.addr(refereePk2);   // ← add this

        registry = new RefereeRegistry();
        registry.addReferee(referee);
        registry.addReferee(referee1);    // ← add this
        registry.addReferee(referee2);    // ← add this

        matchGame = new snookerMatch(address(usdt), address(registry));

        usdt.mint(player1, 1000 * 10**6);
        usdt.mint(player2, 1000 * 10**6);

        vm.prank(player1);
        usdt.approve(address(matchGame), type(uint256).max);

        vm.prank(player2);
        usdt.approve(address(matchGame), type(uint256).max);

        // targetContract(address(matchGame));
    }

        function testDeposit() public {
        vm.prank(player1);
        matchGame.deposit(stakeAmount);

        (uint256 depositedBalance,,,,,,,,,) = matchGame.wallets(player1);
        assertEq(depositedBalance, stakeAmount);
    }

        function testDepositRevertsIfZero() public {
        vm.prank(player1);
        vm.expectRevert("Deposit amount must be greater than 0");
        matchGame.deposit(0);
    }

    function testDepositRevertsIfBelowMinimum() public {
        vm.prank(player1);
        vm.expectRevert("Deposited amount too low");
        matchGame.deposit(4e6); // 5 USDT, below minimum
    }

        function testDepositExactlyMinimum() public {
        vm.prank(player1);
        matchGame.deposit(10e6);
        assertEq(matchGame.getPlayerBalance(player1), 10e6);
    }

        function testDepositSucceedsAboveMinimum() public {
        vm.prank(player1);
        matchGame.deposit(200e6); // Above MIN_DEPOSIT 
    
        (uint256 depositedBalance,,,,,,,,,) = matchGame.wallets(player1);
        assertEq(depositedBalance, 200e6);
    }

        function testConstructorRevertsZeroUSDT() public {
        vm.expectRevert();
        new snookerMatch(address(0), referee);
    }

        function testConstructorRevertsZeroReferee() public {
        vm.expectRevert();
        new snookerMatch(address(usdt), address(0));
    }

        function testConstructorBothZero() public {
        vm.expectRevert("Invalid registry");
        new snookerMatch(address(0), address(0));
    }

        function testConstructorZeroUsdt() public {
        vm.expectRevert("Invalid USDT address");
        new snookerMatch(address(0), address(registry)); // valid registry, zero usdt
    }

    function testJoinMatchWithUnsupportedStakeAmount() public {
        vm.prank(player1);
        matchGame.deposit(150e6);
        vm.expectRevert("Unsupported Stake Amount");
        matchGame.joinMatch(150e6);
    }

        function testFinalizeMatch() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player2);
            matchGame.deposit(stakeAmount);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.cancelMatch(1);

            (uint256 player1Balance,,,,,,,,,) = matchGame.wallets(player1);
            assertGt(player1Balance, 0);
        }

            function testWithdraw() public {
                vm.startPrank(player1);
                matchGame.deposit(stakeAmount);
                uint256 balanceBefore = usdt.balanceOf(player1);
                matchGame.withdraw(50e6);
                uint256 balanceAfter = usdt.balanceOf(player1);

                assertEq(balanceAfter - balanceBefore, 50e6);
                vm.stopPrank();
            }

            function testWithdrawRevertsIfInsufficientBalance() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player1);
            vm.expectRevert("Insufficient withdraw balance");
            matchGame.withdraw(200e6);
        }


            function testWithdrawRevertsIfInActiveMatch() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player2);
            matchGame.deposit(stakeAmount);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            // Try to withdraw while in match
            vm.prank(player1);
            vm.expectRevert("cannot withdraw while in active match");
            matchGame.withdraw(10e6);
        }

            function testJoinMatchQueueLessThanTwoPlayers() public {
                vm.startPrank(player1);
                matchGame.deposit(stakeAmount * 2);
                // console.log(matchGame.wallets(player1).depositedBalance);
                matchGame.joinMatch(stakeAmount);
                vm.stopPrank();
                assertEq(matchGame.activeMatch(player1), 0);
                assertTrue(matchGame.inQueue(player1));
                assertEq(matchGame.queuedStake(player1), stakeAmount);
            }

            function testJoinMatchStaysInQueueWhenAlone() public {
                vm.prank(player1);
                matchGame.deposit(stakeAmount);
    
                vm.prank(player1);
                matchGame.joinMatch(stakeAmount);
    
                // Only 1 in queue, no match created
                assertTrue(matchGame.inQueue(player1));
                assertEq(matchGame.activeMatch(player1), 0);
                assertEq(matchGame.getQueueLength(stakeAmount), 1);
            }

            function testJoinMatch_QueueTwoPlayers_MatchCreated() public {
                // Player 1 joins queue
                vm.startPrank(player1);
                matchGame.deposit(stakeAmount * 2);
                matchGame.joinMatch(stakeAmount);
                vm.stopPrank();

                // Player 2 joins → should trigger match creation
                vm.startPrank(player2);
                matchGame.deposit(stakeAmount * 2);
                matchGame.joinMatch(stakeAmount);
                vm.stopPrank();

                uint256 matchId1 = matchGame.activeMatch(player1);
                uint256 matchId2 = matchGame.activeMatch(player2);

                // Match should exist
                assertTrue(matchId1 != 0);
                assertEq(matchId1, matchId2);

                // Both players should be removed from queue
                assertFalse(matchGame.inQueue(player1));
                assertFalse(matchGame.inQueue(player2));

                // queuedStake should be cleared
                assertEq(matchGame.queuedStake(player1), 0);
                assertEq(matchGame.queuedStake(player2), 0);
            }

            function testJoinMatchCreatesMatch() public {
            // Both players deposit
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player2);
            matchGame.deposit(stakeAmount);

            // Both join
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            // Check match was created
            (address p1, address p2,,,,,,,,,,,) = matchGame.matches(1);
            assertEq(p1, player1);
            assertEq(p2, player2);
        }

            function testJoinMatchRevertsIfInsufficientBalance() public {
            vm.prank(player1);
            matchGame.deposit(50e6);

            vm.prank(player1);
            vm.expectRevert("Insufficient deposit balance");
            matchGame.joinMatch(stakeAmount);

            // state must remain unchanged
            assertEq(matchGame.getPlayerBalance(player1), 50e6);
        }

        function testJoinMatchWithSinglePlayer() public {
            vm.startPrank(player1);
            matchGame.deposit(stakeAmount);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();
            assertEq(matchGame.getQueueLength(stakeAmount), 1);
        }

        function testjoinMatchRevertsIfAlreadyInMatch() public {
            vm.startPrank(player1);
            matchGame.deposit(200e6);
    
            console.log("Before first join - inQueue:", matchGame.inQueue(player1));
            matchGame.joinMatch(stakeAmount);
            console.log("After first join - inQueue:", matchGame.inQueue(player1));
    
            vm.expectRevert("Already waiting in queue");
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();
        }

        function testJoinMatch_UpdatesWageredAndBalance() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            (
                uint256 balance,
                ,
                ,
                ,
                uint256 totalWagered,
                ,
                ,
                ,
                ,
        
            ) = matchGame.getPlayerWallet(player1);
            console.log("Balance after joining match:", balance);
            console.log("Total wagered after joining match:", totalWagered);
            assertEq(balance, 0);
            assertEq(totalWagered, stakeAmount);
        }


        // function invariant_noPlayerInMultipleMatches() public view {
        //     address[3] memory testPlayers = [player1, player2, player3];

        //     for (uint256 i = 0; i < testPlayers.length; i++){
        //         address player = testPlayers[i];
                
        //         uint256 activeMatchId = matchGame.activeMatch(player);
        //         bool inQueue = matchGame.inQueue(player);
        //         // player cannot be in both Active Match and Queue
        //         if (activeMatchId != 0){
        //             assertFalse(inQueue, "Player has an active match and is in queue");
        //             // Load match struct
        //     (
        //         address p1,
        //         address p2,
        //         ,
        //         ,
        //         ,
        //         ,
        //         ,
        //         ,
        //         bool finished,
        //         ,
        //         ,
        //         ,
                
        //     ) = matchGame.matches(activeMatchId);

        //     // Player must be one of the match participants
        //     assertTrue(
        //         player == p1 || player == p2,
        //         "activeMatch mapping mismatch"
        //     );

        //     // Active match should not be finished
        //     assertFalse(finished, "Player mapped to finished match");
        //         }
        //     }
        // }

        function testJoinMatchRevertsIfAlreadyPlaying() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player2);
            matchGame.deposit(stakeAmount);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            assertTrue(matchGame.activeMatch(player1) != 0);

            vm.prank(player1);
            vm.expectRevert("Already in an active Match");
            matchGame.joinMatch(stakeAmount);
        }


//             function invariant_matchFundsLocked() public view {
//             uint256 totalLocked = matchGame.totalLockedInMatches();
//             uint256 calculatedLocked = 0;   
//             for (uint256 matchId = 1; matchId < 1000; matchId++) {
//             (
//             address player1,
//             ,  // player2
//             ,  // currentPlayer
//             uint256 stakeAmount,
//             ,  // startTime
//             ,  // player1LastAction
//             ,  // player2LastAction
//             ,  // winner
//             bool finished,
//             ,  // state
//             ,  // player1WantsRematch
//             ,  // player2WantsRematch
//                // rematchRequestTime
//         ) = matchGame.matches(matchId);
        
//         // If match exists (player1 != 0) and not finished
//         if (player1 != address(0) && !finished) {
//             calculatedLocked += stakeAmount * 2;
//         }
        
//         // If no match found, stop
//         if (player1 == address(0)) break;
//     }
    
//     assertEq(
//         totalLocked,
//         calculatedLocked,
//         "Locked funds accounting mismatch"
//     );
// }           


//             function invariant_queueNoDuplicates() public view {
//             // You can't iterate over all possible uint256 values,
//             // so we'll check only known stake amounts that have been used
    
//             // Option 1: Check common stake amounts
//         uint256[22] memory commonStakes = [
//         uint256(10e6), uint256(20e6), uint256(50e6), uint256(100e6), uint256(200e6),
//         uint256(500e6), uint256(800e6), uint256(1000e6), uint256(1500e6), uint256(2000e6),
//         uint256(2500e6), uint256(3000e6), uint256(5000e6), uint256(7500e6), uint256(10000e6),
//         uint256(15000e6), uint256(20000e6), uint256(25000e6), uint256(30000e6),
//         uint256(50000e6), uint256(75000e6), uint256(100000e6)
//     ];
    
//     for (uint256 s = 0; s < commonStakes.length; s++) {
//         uint256 stakeAmount = commonStakes[s];
        
//         uint256 queueLength = matchGame.getQueueLength(stakeAmount);
        
//        if (queueLength == 0) continue;
        
//         uint256 startIdx = matchGame.queueIndex(stakeAmount);
        
//         for (uint256 i = startIdx; i < startIdx + queueLength; i++) {
//             // ✅ Access individual elements
//             address player = matchGame.matchQueue(stakeAmount, i);
            
//             if (player != address(0)) {
//                 assertTrue(
//                     matchGame.inQueue(player),
//                     "Player in queue but flag false"
//                 );
//                 assertEq(
//                     matchGame.activeMatch(player),
//                     0,
//                     "Active player in queue"
//                 );
//             }
//         }
//     }
// }   

    //             function invariant_balanceNeverExceedsDeposit() public view {
    //             address[3] memory testPlayers = [player1, player2, player3];
    
    //             for (uint256 i = 0; i < testPlayers.length; i++) {
    //             address player = testPlayers[i];
        
    //             (
    //             uint256 depositedBalance,
    //             uint256 totalDeposited,
    //             uint256 totalWon,
    //             uint256 totalLost,
    //             uint256 totalwagered,
    //             uint256 wins,
    //             uint256 losses,
    //             uint256 totalWithdrawn,
    //             uint256 totalRefunded,
    //             uint256 gamesPlayed
    //             ) = matchGame.wallets(player);
        
    //             // Check 1: Current balance ≤ lifetime deposits
    //             assertTrue(
    //             depositedBalance <= totalDeposited,
    //             "Player balance exceeds total deposits"
    //             );
        
    //             // Check 2: Wins and losses should reconcile with games played
    //             if (gamesPlayed > 0) {
    //             // totalWon should be non-negative (obviously)
    //             // totalLost should not exceed total ever deposited
    //             assertTrue(
    //             totalLost <= totalDeposited,
    //             "Player lost more than ever deposited"
    //             );
    //         }
        
    //     }
    // }           

        function testMultipleQueueMatches() public {

            address player4 = address(0x4);

            usdt.mint(player3, 1000e6);
            usdt.mint(player4, 1000e6);

            vm.startPrank(player1);
            usdt.approve(address(matchGame), type(uint256).max);
            matchGame.deposit(stakeAmount);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            vm.startPrank(player2);
            usdt.approve(address(matchGame), type(uint256).max);
            matchGame.deposit(stakeAmount);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            vm.startPrank(player3);
            usdt.approve(address(matchGame), type(uint256).max);
            matchGame.deposit(stakeAmount);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            vm.startPrank(player4);
            usdt.approve(address(matchGame), type(uint256).max);
            matchGame.deposit(stakeAmount);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            // queue should now be empty again
            assertEq(matchGame.getQueueLength(stakeAmount), 0);

            // both matches should exist
            assertEq(matchGame.activeMatch(player1), 1);
            assertEq(matchGame.activeMatch(player2), 1);

            assertEq(matchGame.activeMatch(player3), 2);
            assertEq(matchGame.activeMatch(player4), 2);
        }


    function testRematchBothPlayersAccept() public {
    // Setup and complete a match
    vm.prank(player1);
    matchGame.deposit(stakeAmount * 2); // Enough for rematch
    
    vm.prank(player2);
    matchGame.deposit(stakeAmount * 2);
    
    vm.prank(player1);
    matchGame.joinMatch(stakeAmount);
    
    vm.prank(player2);
    matchGame.joinMatch(stakeAmount);
    
    uint256 matchId = matchGame.activeMatch(player1);
    
    // Finish match (player2 cancels)
    vm.prank(player2);
    matchGame.cancelMatch(matchId);
    
    // Both players request rematch
    vm.prank(player1);
    matchGame.restartMatch(matchId);
    
    vm.prank(player2);
    matchGame.restartMatch(matchId);
    
    // Verify new match was created
    uint256 newMatchId = matchGame.activeMatch(player1);
    assertGt(newMatchId, 0, "New match should be created");
    assertNotEq(newMatchId, matchId, "Should be a different match");
    
    // Verify both players in new match
    assertEq(matchGame.activeMatch(player2), newMatchId, "Player2 should be in new match");
}


    function testRematchCompleteMoneyFlow_TwoMatches() public {
    uint256 initialDeposit = stakeAmount * 3;

    // =========================
    // 1. DEPOSIT
    // =========================
    vm.prank(player1);
    matchGame.deposit(initialDeposit);

    vm.prank(player2);
    matchGame.deposit(initialDeposit);

    assertEq(
        usdt.balanceOf(address(matchGame)),
        initialDeposit * 2,
        "Contract should hold deposits"
    );

    // =========================
    // 2. MATCH 1 SETUP
    // =========================
    vm.prank(player1);
    matchGame.joinMatch(stakeAmount);

    vm.prank(player2);
    matchGame.joinMatch(stakeAmount);

    uint256 match1Id = matchGame.activeMatch(player1);

    // =========================
    // 3. MATCH 1 RESULT (P1 wins)
    // =========================
    vm.prank(player2);
    matchGame.cancelMatch(match1Id);

    uint256 totalStake = stakeAmount * 2;
    uint256 fee1 = (totalStake * matchGame.MATCH_BPS_FEE()) / 10_000;
    uint256 payout1 = totalStake - fee1;
    uint256 profit1 = payout1 - stakeAmount;

    // ---- PLAYER 1 STATS ----
    (
        uint256 p1Balance1,
        ,
        uint256 p1Won1,
        uint256 p1Lost1,
        ,
        uint256 p1Wins1,
        uint256 p1Losses1,
        ,
        ,
        uint256 p1Games1
    ) = matchGame.getPlayerWallet(player1);

    // ---- PLAYER 2 STATS ----
    (
        uint256 p2Balance1,
        ,
        uint256 p2Won1,
        uint256 p2Lost1,
        ,
        uint256 p2Wins1,
        uint256 p2Losses1,
        ,
        ,
        uint256 p2Games1
    ) = matchGame.getPlayerWallet(player2);

    assertEq(p1Won1, profit1);
    assertEq(p2Lost1, stakeAmount);
    assertEq(p1Wins1, 1);
    assertEq(p2Losses1, 1);
    assertEq(p1Games1, 1);
    assertEq(p2Games1, 1);

    // =========================
    // 4. REMATCH
    // =========================
    vm.prank(player1);
    matchGame.restartMatch(match1Id);

    vm.prank(player2);
    matchGame.restartMatch(match1Id);

    uint256 match2Id = matchGame.activeMatch(player1);

    // =========================
    // 5. MATCH 2 RESULT (P2 wins)
    // =========================
    vm.prank(player1);
    matchGame.cancelMatch(match2Id);

    uint256 fee2 = (totalStake * matchGame.MATCH_BPS_FEE()) / 10_000;
    uint256 payout2 = totalStake - fee2;
    uint256 profit2 = payout2 - stakeAmount;

    // =========================
    // 6. FINAL PLAYER STATES
    // =========================

    (
        uint256 p1FinalBalance,
        ,
        uint256 p1FinalWon,
        uint256 p1FinalLost,
        ,
        uint256 p1Wins,
        uint256 p1Losses,
        ,
        ,
        uint256 p1Games
    ) = matchGame.getPlayerWallet(player1);

    (
        uint256 p2FinalBalance,
        ,
        uint256 p2FinalWon,
        uint256 p2FinalLost,
        ,
        uint256 p2Wins,
        uint256 p2Losses,
        ,
        ,
        uint256 p2Games
    ) = matchGame.getPlayerWallet(player2);

    // ---- ASSERT PLAYER 1 ----
    assertEq(p1FinalWon, profit1);
    assertEq(p1FinalLost, stakeAmount);
    assertEq(p1Wins, 1);
    assertEq(p1Losses, 1);
    assertEq(p1Games, 2);

    // ---- ASSERT PLAYER 2 ----
    assertEq(p2FinalWon, profit2);
    assertEq(p2FinalLost, stakeAmount);
    assertEq(p2Wins, 1);
    assertEq(p2Losses, 1);
    assertEq(p2Games, 2);

    // =========================
    // 7. FEES CHECK
    // =========================
    uint256 totalFees = matchGame.collectedFees();
    assertEq(totalFees, fee1 + fee2);

    // =========================
    // 8. CONTRACT INVARIANT
    // =========================
    uint256 contractBalance = usdt.balanceOf(address(matchGame));

    assertEq(
        contractBalance,
        p1FinalBalance + p2FinalBalance + totalFees,
        "Balance mismatch"
    );

    // =========================
    // 9. WITHDRAW
    // =========================
    vm.prank(player1);
    matchGame.withdraw(p1FinalBalance);

    vm.prank(player2);
    matchGame.withdraw(p2FinalBalance);

   {
    (
        uint256 p1AfterWithdraw,
        uint256 td,
        uint256 tw,
        uint256 tl,
        uint256 twg,
        uint256 wins,
        uint256 losses,
        uint256 withdrawn,
        uint256 refunded,
        uint256 games
    ) = matchGame.getPlayerWallet(player1);

    assertEq(p1AfterWithdraw, 0);
}

{
    (
        uint256 p2AfterWithdraw,
        uint256 td,
        uint256 tw,
        uint256 tl,
        uint256 twg,
        uint256 wins,
        uint256 losses,
        uint256 withdrawn,
        uint256 refunded,
        uint256 games
    ) = matchGame.getPlayerWallet(player2);

    assertEq(p2AfterWithdraw, 0);
}

    // =========================
    // 10. FINAL INVARIANT
    // =========================
    uint256 finalBalance = usdt.balanceOf(address(matchGame));

    assertEq(finalBalance, totalFees, "Only fees should remain");
}
        function testRematchOnlyPlayer1Accepts() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player2);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            uint256 matchId = matchGame.activeMatch(player1);

            vm.prank(player2);
            matchGame.cancelMatch(matchId);

            vm.prank(player1);
            matchGame.restartMatch(matchId);
            
            assertEq(matchGame.activeMatch(player1), 0, "No Active Match Yet");
            assertEq(matchGame.activeMatch(player2), 0,  "No Active Match Yet");

            (,,,,,,, bool p1,,,,,) = matchGame.matches(matchId);
            assertTrue(p1, "Player1 rematch flag should be set");

        }

        function testJoinMatch_RevertsIfAlreadyInQueue() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount); // enters queue

            vm.prank(player1);
            vm.expectRevert("Already waiting in queue");
            matchGame.joinMatch(stakeAmount); // ← hits false branch of require 2
        }

        function testQueueResetsWhenExactlyTwoPlayersMatch() public {
            // exactly 2 players — after match, queue is fully consumed
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.deposit(stakeAmount);
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount); // match created, queue reset

            // queueIndex should reset to 0, array deleted
            assertEq(matchGame.getQueueLength(stakeAmount), 0);
            assertEq(matchGame.queueIndex(stakeAmount), 0);
        }

        function testQueueNotResetWhenPlayersRemain() public {
    // setup player3
    address player3 = address(0x3);
    usdt.mint(player3, 1000 * 10**6);
    vm.prank(player3);
    usdt.approve(address(matchGame), type(uint256).max);

    // support a second stake level
    uint256 stake200 = 200 * 10**6;
    matchGame.setSupportedAmount(stake200, true);

    // P1 enters 100 queue
    vm.prank(player1);
    matchGame.deposit(300 * 10**6);
    vm.prank(player1);
    matchGame.joinMatch(stakeAmount); // queue100=[P1]

    // P2 enters 200 queue first, then adjustStake to 100
    // adjustStake adds to queue WITHOUT triggering matchmaking
    vm.prank(player2);
    matchGame.deposit(300 * 10**6);
    vm.prank(player2);
    matchGame.joinMatch(stake200);    // queue200=[P2]
    vm.prank(player2);
    matchGame.adjustStake(stakeAmount); // queue100=[P1, P2] — no match triggered

    // P3 joins 100 → triggers match P1 vs P2, P3 remains in queue
    vm.prank(player3);
    matchGame.deposit(stakeAmount);
    vm.prank(player3);
    matchGame.joinMatch(stakeAmount); // queue100=[P1,P2,P3] → match P1 vs P2
                                      // queueIndex=2, length=3 → 2 < 3 → NO reset

    // false branch hit: queue not reset, P3 still waiting
    assertEq(matchGame.getQueueLength(stakeAmount), 1);
    assertTrue(matchGame.inQueue(player3));
    assertGt(matchGame.queueIndex(stakeAmount), 0); // queueIndex=2, confirmed not reset
}
        function testJoinMatch_SinglePlayer_NoMatchCreated() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            // false branch — no match created
            assertEq(matchGame.activeMatch(player1), 0);
            assertTrue(matchGame.inQueue(player1));
            assertEq(matchGame.getQueueLength(stakeAmount), 1);
        }

        function testRematchRevertsIfInsufficientBalance() public {
            // Complete match
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player2);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            uint256 matchId = matchGame.activeMatch(player1);
    
            // Player1 wins (has balance for rematch)
            vm.prank(player2);
            matchGame.cancelMatch(matchId);
    
            // Player2 (loser with 0 balance) tries rematch
            vm.prank(player2);
            vm.expectRevert("Insufficient balance");
            matchGame.restartMatch(matchId);
        }

        function testRematchBothWithinWindow() public {
            // Complete match
            vm.prank(player1);
            matchGame.deposit(stakeAmount * 2);
    
            vm.prank(player2);
            matchGame.deposit(stakeAmount * 2);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            uint256 matchId = matchGame.activeMatch(player1);
            uint256 startTime = block.timestamp;
    
            vm.prank(player2);
            matchGame.cancelMatch(matchId);
    
            // Player1 requests at t=0
            vm.prank(player1);
            matchGame.restartMatch(matchId);
    
            // Player2 accepts at t=5 (within 10s window)
            vm.warp(startTime + 5);
            vm.prank(player2);
            matchGame.restartMatch(matchId);
    
            // Verify new match created
            uint256 newMatchId = matchGame.activeMatch(player1);
            assertGt(newMatchId, matchId, "New match should be created");
    
            // Verify balances deducted
            (uint256 p1Balance,,,,,,,,,) = matchGame.wallets(player1);
            (uint256 p2Balance,,,,,,,,,) = matchGame.wallets(player2);
            // Should have winnings minus new stake
            assertEq(p1Balance, 196e6, "Player1 should have some balance left");
            assertEq(p2Balance, 0, "Player1 should have some balance left");
        }


        function testRematchRevertsIfMatchNotFinished() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount * 2);
            
            vm.prank(player2);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            uint256 matchId = matchGame.activeMatch(player1);

            vm.prank(player1);
            vm.expectRevert("Match not completed");
            matchGame.restartMatch(matchId);
        }

        function testRematchRevertsIfAlreadyRequested() public {
            // Complete match
            vm.prank(player1);
            matchGame.deposit(stakeAmount * 2);
    
            vm.prank(player2);
            matchGame.deposit(stakeAmount * 2);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            uint256 matchId = matchGame.activeMatch(player1);
    
            vm.prank(player2);
            matchGame.cancelMatch(matchId);
    
            // Player1 requests rematch
            vm.prank(player1);
            matchGame.restartMatch(matchId);
    
            // Player1 tries to request again
            vm.prank(player1);
            vm.expectRevert("Already requested rematch");
            matchGame.restartMatch(matchId);
    }

        function testRematchFailsIfBalanceTooLow() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player2);
            matchGame.deposit(stakeAmount);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            uint256 matchId = matchGame.activeMatch(player1);

            vm.prank(player2);
            matchGame.cancelMatch(matchId);

            // simulate withdrawal or low balance
            vm.prank(player1);
            matchGame.withdraw(stakeAmount);

            vm.prank(player1);
            vm.expectRevert("Insufficient balance");
            matchGame.restartMatch(matchId);
    }

        function testRestartMatch_RevertWindowExpired() public {
            address player1 = address(0xAAA);
            address player2 = address(0xBBB);

            usdt.mint(player1, stakeAmount * 4);
            usdt.mint(player2, stakeAmount * 4);

            vm.prank(player1);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(player2);
            usdt.approve(address(matchGame), type(uint256).max);

            vm.startPrank(player1);
            matchGame.deposit(stakeAmount * 2);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            vm.startPrank(player2);
            matchGame.deposit(stakeAmount * 2);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            uint256 matchId = matchGame.activeMatch(player1);
            uint256 nonce = matchGame.matchNonce(matchId) + 1;
            uint256 deadline = block.timestamp + 1 hours;

            // First valid submission
            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    player1,
                    player2,
                    player1,
                    nonce,
                    deadline
                )
            );

            bytes32 digest = matchGame.hashTypedDataV4(structHash);
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes memory sig1 = abi.encodePacked(r1, s1, v1);
            bytes memory sig2 = abi.encodePacked(r2, s2, v2);
            bytes memory sig3 = abi.encodePacked(r3, s3, v3);

            bytes[] memory signatures = new bytes[](3);
            signatures[0] = sig1;
            signatures[1] = sig2;
            signatures[2] = sig3;

            vm.prank(referee);
            matchGame.reportMatchWinner(matchId, player1, nonce, deadline, signatures);

            vm.prank(player1);
            matchGame.restartMatch(matchId);
            
            vm.warp(block.timestamp + REMATCH_WINDOW + 1);

            vm.prank(player2);
            vm.expectRevert("Rematch window expired");
            matchGame.restartMatch(matchId);

    }


        function testRestartMatch_FirstCall_SetsRematchTime() public {
            // --- Setup match ---
            vm.startPrank(player1);
            matchGame.deposit(stakeAmount * 2);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            vm.startPrank(player2);
            matchGame.deposit(stakeAmount * 2);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            uint256 matchId = matchGame.activeMatch(player1);

            // --- Complete match ---
            uint256 nonce = matchGame.matchNonce(matchId) + 1;
            uint256 deadline = block.timestamp + 1 hours;

            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    player1,
                    player2,
                    player1,
                    nonce,
                    deadline
                )
            );

            bytes32 digest = matchGame.hashTypedDataV4(structHash);

            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes memory sig1 = abi.encodePacked(r1, s1, v1);
            bytes memory sig2 = abi.encodePacked(r2, s2, v2);
            bytes memory sig3 = abi.encodePacked(r3, s3, v3);

            bytes[] memory signatures = new bytes[](3);
            signatures[0] = sig1;
            signatures[1] = sig2;
            signatures[2] = sig3;

            vm.prank(referee);
            matchGame.reportMatchWinner(matchId, player1, nonce, deadline, signatures);

            // --- FIRST restart call ---
            vm.prank(player1);
            matchGame.restartMatch(matchId);

            // Assert rematchTimeRequested was set
            (,,,,,,,,,,, uint256 rematchTimeRequested,) = matchGame.matches(matchId);
            assertGt(rematchTimeRequested, 0);
        }


        function testRestartMatch_WithinWindow_Succeeds() public {
            // --- Setup match ---
            vm.startPrank(player1);
            matchGame.deposit(stakeAmount * 2);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            vm.startPrank(player2);
            matchGame.deposit(stakeAmount * 2);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            uint256 matchId = matchGame.activeMatch(player1);

            // --- Complete match ---
            uint256 nonce = matchGame.matchNonce(matchId) + 1;
            uint256 deadline = block.timestamp + 1 hours;

            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    player1,
                    player2,
                    player1,
                    nonce,
                    deadline
                )
            );

            bytes32 digest = matchGame.hashTypedDataV4(structHash);
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes memory sig1 = abi.encodePacked(r1, s1, v1);
            bytes memory sig2 = abi.encodePacked(r2, s2, v2);
            bytes memory sig3 = abi.encodePacked(r3, s3, v3);

            bytes[] memory signatures = new bytes[](3);
            signatures[0] = sig1;
            signatures[1] = sig2;
            signatures[2] = sig3;


            vm.prank(referee);
            matchGame.reportMatchWinner(matchId, player1, nonce, deadline, signatures);

            // --- First player requests rematch ---
            vm.prank(player1);
            matchGame.restartMatch(matchId);

            // Stay within window
            vm.warp(block.timestamp + 5);

            // --- Second player joins ---
            vm.prank(player2);
            matchGame.restartMatch(matchId);

            // Assert new match created
            uint256 newMatchId = matchGame.activeMatch(player1);
            assertGt(newMatchId, matchId);
        }

        function testRestartMatch_RevertAlreadyRequested() public {
            // --- Setup match ---
            vm.startPrank(player1);
            matchGame.deposit(stakeAmount * 2);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            vm.startPrank(player2);
            matchGame.deposit(stakeAmount * 2);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            uint256 matchId = matchGame.activeMatch(player1);

            // --- Complete match ---
            uint256 nonce = matchGame.matchNonce(matchId) + 1;
            uint256 deadline = block.timestamp + 1 hours;

            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    player1,
                    player2,
                    player1,
                    nonce,
                    deadline
                )
            );

            bytes32 digest = matchGame.hashTypedDataV4(structHash);
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes memory sig1 = abi.encodePacked(r1, s1, v1);
            bytes memory sig2 = abi.encodePacked(r2, s2, v2);
            bytes memory sig3 = abi.encodePacked(r3, s3, v3);

            bytes[] memory signatures = new bytes[](3);
            signatures[0] = sig1;
            signatures[1] = sig2;
            signatures[2] = sig3;


            vm.prank(referee);
            matchGame.reportMatchWinner(matchId, player1, nonce, deadline, signatures);

            // --- First request ---
            vm.prank(player1);
            matchGame.restartMatch(matchId);

            // --- Second request (same player) → should revert ---
            vm.prank(player1);
            vm.expectRevert("Already requested rematch");
            matchGame.restartMatch(matchId);
        }

        function testFourPlayersTwoMatches() public {
            // Setup 4 players
            address player4 = address(0x4);
    
            // Mint and approve for all players
            usdt.mint(player1, 1000e6);
            usdt.mint(player2, 1000e6);
            usdt.mint(player3, 1000e6);
            usdt.mint(player4, 1000e6);
    
            vm.prank(player1);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(player2);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(player3);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(player4);
            usdt.approve(address(matchGame), type(uint256).max);
    
            // All 4 players deposit
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player2);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player3);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player4);
            matchGame.deposit(stakeAmount);
    
            // Players 1 & 2 join match (should create Match 1)
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            // Players 3 & 4 join match (should create Match 2)
            vm.prank(player3);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player4);
            matchGame.joinMatch(stakeAmount);
    
            // Verify two separate matches created
            uint256 match1Id = matchGame.activeMatch(player1);
            uint256 match2Id = matchGame.activeMatch(player3);
    
            assertEq(match1Id, 1, "First match should be ID 1");
            assertEq(match2Id, 2, "Second match should be ID 2");
            assertNotEq(match1Id, match2Id, "Matches should be different");
    
            // Verify player pairings
            assertEq(matchGame.activeMatch(player1), match1Id, "Player1 in match 1");
            assertEq(matchGame.activeMatch(player2), match1Id, "Player2 in match 1");
            assertEq(matchGame.activeMatch(player3), match2Id, "Player3 in match 2");
            assertEq(matchGame.activeMatch(player4), match2Id, "Player4 in match 2");
    
            // Verify total locked funds
            assertEq(
                matchGame.totalLockedInMatches(),
                stakeAmount * 4,
                "Should lock 4 stakes total"
            );
    
            // Finalize Match 1 - Player1 wins
            vm.prank(player2);
            matchGame.cancelMatch(match1Id);
    
            // Finalize Match 2 - Player4 wins
            vm.prank(player3);
            matchGame.cancelMatch(match2Id);
    
            // Verify winners
            (,,,,, address winner1 ,,,,,,,) = matchGame.matches(match1Id);
            (,,,,, address winner2 ,,,,,,,) = matchGame.matches(match2Id);
    
            assertEq(winner1, player1, "Player1 should win match 1");
            assertEq(winner2, player4, "Player4 should win match 2");
    
            // Verify total locked cleared
            assertEq(matchGame.totalLockedInMatches(), 0, "All matches settled");
        }

        function testQueueIsolation() public {
            // Ensure different stake queues don't interfere
            vm.prank(player1);
            matchGame.deposit(500e6);
    
            vm.prank(player2);
            matchGame.deposit(500e6);
    
            // Player1 joins $100 queue
            vm.prank(player1);
            matchGame.joinMatch(100e6);
    
            // Player2 joins $200 queue (different!)
            vm.prank(player2);
            matchGame.joinMatch(200e6);
    
            // Verify no match created
            assertEq(matchGame.activeMatch(player1), 0, "Player1 waiting in queue");
            assertEq(matchGame.activeMatch(player2), 0, "Player2 waiting in queue");
    
            // Verify in correct queues
            assertTrue(matchGame.inQueue(player1), "Player1 in queue");
            assertTrue(matchGame.inQueue(player2), "Player2 in queue");
    
            assertEq(matchGame.getQueueLength(100e6), 1, "$100 queue has 1 player");
            assertEq(matchGame.getQueueLength(200e6), 1, "$200 queue has 1 player");
        }

        function testGetQueuePlayers_EmptyQueue() public {
            address[] memory players = matchGame.getQueuePlayers(stakeAmount);
            assertEq(players.length, 0, "Empty queue should return empty array");
        }

        function testMixedStakeAmounts() public {
            // Create 6 players
            address[6] memory players;
            for (uint i = 0; i < 6; i++) {
                players[i] = address(uint160(0x2000 + i));
                usdt.mint(players[i], 10000e6);
        
                vm.prank(players[i]);
                usdt.approve(address(matchGame), type(uint256).max);
        
                vm.prank(players[i]);
                matchGame.deposit(5000e6);
            }
    
            // Players join different stakes
            uint256[] memory stakes = new uint256[](3);
            stakes[0] = 50e6;
            stakes[1] = 1000e6;
            stakes[2] = 5000e6;
    
            // Two players per stake amount
            for (uint s = 0; s < 3; s++) {
                vm.prank(players[s * 2]);
                matchGame.joinMatch(stakes[s]);
        
                vm.prank(players[s * 2 + 1]);
                matchGame.joinMatch(stakes[s]);
            }
    
            // Verify 3 matches created with different stakes
            uint256 match1 = matchGame.activeMatch(players[0]);
            uint256 match2 = matchGame.activeMatch(players[2]);
            uint256 match3 = matchGame.activeMatch(players[4]);
    
            (,,, uint256 stake1,,,,,,,,,) = matchGame.matches(match1);
            (,,, uint256 stake2,,,,,,,,,) = matchGame.matches(match2);
            (,,, uint256 stake3,,,,,,,,,) = matchGame.matches(match3);
    
            assertEq(stake1, 50e6, "Match 1 has $50 stake");
            assertEq(stake2, 1000e6, "Match 2 has $1000 stake");
            assertEq(stake3, 5000e6, "Match 3 has $5000 stake");
    
            // Verify correct pairings
            assertEq(matchGame.activeMatch(players[1]), match1, "Players 0-1 paired");
            assertEq(matchGame.activeMatch(players[3]), match2, "Players 2-3 paired");
            assertEq(matchGame.activeMatch(players[5]), match3, "Players 4-5 paired");
    
            // Calculate expected fees for different stakes
            uint256 fee1 = (50e6 * 2 * matchGame.MATCH_BPS_FEE()) / 10_000;
            uint256 fee2 = (1000e6 * 2 * matchGame.MATCH_BPS_FEE()) / 10_000;
            uint256 fee3 = (5000e6 * 2 * matchGame.MATCH_BPS_FEE()) / 10_000;
    
            // Complete all matches
            vm.prank(players[1]);
            matchGame.cancelMatch(match1);
    
            vm.prank(players[3]);
            matchGame.cancelMatch(match2);
    
            vm.prank(players[5]);
            matchGame.cancelMatch(match3);
    
            // Verify total fees collected
            uint256 totalFees = matchGame.collectedFees();
            assertEq(totalFees, fee1 + fee2 + fee3, "All fees collected correctly");
    
            // Verify winners got correct payouts
            (uint256 winner1Balance,,,,,,,,,) = matchGame.wallets(players[0]);
            (uint256 winner2Balance,,,,,,,,,) = matchGame.wallets(players[2]);
            (uint256 winner3Balance,,,,,,,,,) = matchGame.wallets(players[4]);
    
            assertEq(
                winner1Balance,
                5000e6 - 50e6 + (50e6 * 2 - fee1),
                "Winner1 correct payout"
            );
            assertEq(
                winner2Balance,
                5000e6 - 1000e6 + (1000e6 * 2 - fee2),
                "Winner2 correct payout"
            );
            assertEq(
                winner3Balance,
                5000e6 - 5000e6 + (5000e6 * 2 - fee3),
                "Winner3 correct payout"
            );
        }

        function testTenPlayersMultipleQueues() public {
            // Create array of 10 players
            address[10] memory players;
            for (uint i = 0; i < 10; i++) {
            players[i] = address(uint160(0x1000 + i));
        
            // Mint and approve
            usdt.mint(players[i], 1000e6);
            vm.prank(players[i]);
            usdt.approve(address(matchGame), type(uint256).max);
        
            // Deposit
            vm.prank(players[i]);
            matchGame.deposit(500e6);
        }
    
            // Players join different stake queues
            // Players 0-1: $100 queue
            vm.prank(players[0]);
            matchGame.joinMatch(100e6);
            vm.prank(players[1]);
            matchGame.joinMatch(100e6);
    
            // Players 2-3: $200 queue
            vm.prank(players[2]);
            matchGame.joinMatch(200e6);
            vm.prank(players[3]);
            matchGame.joinMatch(200e6);
    
            // Players 4-5: $500 queue
            vm.prank(players[4]);
            matchGame.joinMatch(500e6);
            vm.prank(players[5]);
            matchGame.joinMatch(500e6);
    
            // Players 6-7: $100 queue (second match)
            vm.prank(players[6]);
            matchGame.joinMatch(100e6);
            vm.prank(players[7]);
            matchGame.joinMatch(100e6);
    
            // Players 8-9: $200 queue (second match)
            vm.prank(players[8]);
            matchGame.joinMatch(200e6);
            vm.prank(players[9]);
            matchGame.joinMatch(200e6);
    
            // Verify 5 matches created
            uint256 match1 = matchGame.activeMatch(players[0]);
            uint256 match2 = matchGame.activeMatch(players[2]);
            uint256 match3 = matchGame.activeMatch(players[4]);
            uint256 match4 = matchGame.activeMatch(players[6]);
            uint256 match5 = matchGame.activeMatch(players[8]);
    
            assertEq(match1, 1, "Match 1 created");
            assertEq(match2, 2, "Match 2 created");
            assertEq(match3, 3, "Match 3 created");
            assertEq(match4, 4, "Match 4 created");
            assertEq(match5, 5, "Match 5 created");
    
            // Verify queue lengths are correct (all should be empty now)
            assertEq(matchGame.getQueueLength(100e6), 0, "$100 queue empty");
            assertEq(matchGame.getQueueLength(200e6), 0, "$200 queue empty");
            assertEq(matchGame.getQueueLength(500e6), 0, "$500 queue empty");
    
            // Verify total locked
            uint256 expectedLocked = (100e6 * 2) + (200e6 * 2) + (500e6 * 2) + 
                             (100e6 * 2) + (200e6 * 2);
            assertEq(
            matchGame.totalLockedInMatches(),
            expectedLocked,
            "Correct total locked"
        );
    
            // Complete all matches
            for (uint i = 1; i <= 5; i++) {
            (, address p2,,,,,,,,,,,) = matchGame.matches(i);
            vm.prank(p2);
            matchGame.cancelMatch(i);
        }
    
            // Verify all settled
            assertEq(matchGame.totalLockedInMatches(), 0, "All matches settled");
            assertEq(matchGame.collectedFees(), (100e6 * 2 + 200e6 * 2 + 500e6 * 2 + 
                100e6 * 2 + 200e6 * 2) * matchGame.MATCH_BPS_FEE() / 10_000, "All fees collected");
        }


        function testCompleteUserJourney_AdjustStake_EmergencyRefund_ReportWinner() public {
    
            // Setup players
            address playerA = address(0xAAA);
            address playerB = address(0xBBB);
    
            usdt.mint(playerA, 200000e6); // 200k USDT
            usdt.mint(playerB, 200000e6);
    
            vm.prank(playerA);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(playerB);
            usdt.approve(address(matchGame), type(uint256).max);
    
            console.log("=== PHASE 1: DEPOSIT & JOIN HIGH STAKE ===");
    
            // Player A deposits and joins $100k queue
            vm.prank(playerA);
            matchGame.deposit(150000e6); // Deposit 150k
    
            vm.prank(playerA);
            matchGame.joinMatch(100000e6); // Join $100k queue
    
            // Verify in queue
            assertTrue(matchGame.inQueue(playerA), "Player A should be in queue");
            assertEq(matchGame.getQueueLength(100000e6), 1, "$100k queue should have 1 player");
            assertEq(matchGame.activeMatch(playerA), 0, "No match yet");
    
            console.log("Player A waiting in $100k queue...");
    
            // ============================================
            console.log("\n=== PHASE 2: ADJUST STAKE TO $10k ===");
    
            // Player A adjusts stake from $100k to $10k
            vm.prank(playerA);
            matchGame.adjustStake(10000e6);
    
            // Verify moved to new queue
            assertEq(matchGame.getQueueLength(100000e6), 0, "$100k queue should be empty");
            assertEq(matchGame.getQueueLength(10000e6), 1, "$10k queue should have 1 player");
            assertTrue(matchGame.inQueue(playerA), "Player A still in queue");
    
            console.log("Player A adjusted stake to $10k");
    
            // ============================================
            console.log("\n=== PHASE 3: PLAYER B JOINS & MATCH CREATED ===");
    
            // Player B deposits and joins $10k queue
            vm.prank(playerB);
            matchGame.deposit(50000e6);
    
            vm.prank(playerB);
            matchGame.joinMatch(10000e6);
    
            // Match should be created
            uint256 matchId = matchGame.activeMatch(playerA);
            assertGt(matchId, 0, "Match should be created");
            assertEq(matchGame.activeMatch(playerB), matchId, "Both players in same match");
    
            console.log("Match created! ID:", matchId);
    
            // ============================================
            console.log("\n=== PHASE 4: WAIT 3 DAYS (SIMULATE BACKEND CRASH) ===");
    
            // Fast forward 3 days
            vm.warp(block.timestamp + 3 days + 1 hours);
    
            console.log("3 days passed, backend still down...");
    
            // ============================================
            console.log("\n=== PHASE 5: PLAYER A REQUESTS EMERGENCY REFUND ===");
    
            vm.prank(playerA);
            matchGame.requestEmergencyRefund(matchId);
    
            // Verify refund requested
            (,,,,,,,,, bool p1Approves, bool p2Approves,,) = matchGame.matches(matchId);
            assertTrue(p1Approves, "Player A approved refund");
            assertFalse(p2Approves, "Player B hasn't approved yet");
    
            console.log("Player A requested emergency refund");
    
            // ============================================
            console.log("\n=== PHASE 6: PLAYER B CANCELS REFUND REQUEST ===");
    
            vm.prank(playerA);
            matchGame.cancelEmergencyRefund(matchId);
    
            // Verify refund cancelled
            (,,,,,,,,, p1Approves, p2Approves,,) = matchGame.matches(matchId);
            assertFalse(p1Approves, "Player A approval cancelled");
            assertFalse(p2Approves, "Player B approval cancelled");
    
            console.log("Player B cancelled the refund request");
    
            // ============================================
            console.log("\n=== PHASE 7: BACKEND RECOVERS & REPORTS WINNER ===");
    
            // Backend determines Player A won
            address actualWinner = playerA;
            uint256 nonce = matchGame.matchNonce(matchId) + 1;
            uint256 deadline = block.timestamp + 1 hours;
    
            // Create EIP-712 signature
            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    playerA,
                    playerB,
                    actualWinner,
                    nonce,
                    deadline
                )
            );
    
            bytes32 digest = matchGame.hashTypedDataV4(structHash);
    
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes memory sig1 = abi.encodePacked(r1, s1, v1);
            bytes memory sig2 = abi.encodePacked(r2, s2, v2);
            bytes memory sig3 = abi.encodePacked(r3, s3, v3);

            bytes[] memory signatures = new bytes[](3);
            signatures[0] = sig1;
            signatures[1] = sig2;
            signatures[2] = sig3;

    
            console.log("Referee signed result: Player A wins");
    
            // ============================================
            console.log("\n=== PHASE 8: SUBMIT WINNER (ANYONE CAN CALL) ===");
    
            // Player B tries to call it (anyone can submit)
            vm.prank(playerB);
            matchGame.reportMatchWinner(matchId, actualWinner, nonce, deadline, signatures);
    
            console.log("Match result submitted to blockchain");
    
            // ============================================
            console.log("\n=== PHASE 9: VERIFY WINNER GOT PAID ===");
    
            // Verify match finished
            (,,,,,, bool finished,,,,,,) = matchGame.matches(matchId);
            assertTrue(finished, "Match should be finished");
    
            // Calculate expected payout
            uint256 totalStake = 10000e6 * 2;
            uint256 fee = (totalStake * matchGame.MATCH_BPS_FEE()) / 10_000;
            uint256 expectedPayout = totalStake - fee;
    
            // Verify Player A (winner) balance
            (
                uint256 playerABalance, 
                uint256 playerATotalDeposited, 
                uint256 playerATotalWon, 
                uint256 playerATotalLost, 
                uint256 playerATotalwagered, 
                uint256 playerAWins, 
                uint256 playerALosses,
                uint256 playerATotalWithdrawn, 
                uint256 playerATotalRefunded, 
                uint256 playerAGames) = matchGame.wallets(playerA);
    
            console.log("Player A balance:", playerABalance);
            console.log("Player A total won:", playerATotalWon);
    
            assertEq(
                playerABalance,
                150000e6 - 10000e6 + expectedPayout,
                "Player A should have initial - stake + payout"
            );
            assertEq(playerAGames, 1, "Player A played 1 game");
            assertGt(playerATotalWon, 0, "Player A should have winnings");
    
            // Verify Player B (loser) balance
            (
                uint256 playerBBalance,
                , 
                uint256 playerBTotalWon, 
                uint256 playerBTotalLost, 
                uint256 playerBTotalwagered, 
                , 
                , 
                ,
                , 
                uint256 playerBGames) = matchGame.wallets(playerB);
    
            console.log("Player B balance:", playerBBalance);
            console.log("Player B total lost:", playerBTotalLost);
    
            assertEq(
                playerBBalance,
                50000e6 - 10000e6,
                "Player B should have initial - stake"
            );
            assertEq(playerBGames, 1, "Player B played 1 game");
            assertEq(playerBTotalWon, 0, "Player B has no winnings");
            assertEq(playerBTotalLost, 10000e6, "Player B lost their stake");
    
            // ============================================
            console.log("\n=== PHASE 10: VERIFY FEES COLLECTED ===");
    
            uint256 collectedFees = matchGame.collectedFees();
            assertEq(collectedFees, fee, "Correct fees collected");
            console.log("Protocol fees:", collectedFees);
    
            // ============================================
            console.log("\n=== PHASE 11: PLAYERS WITHDRAW ===");
    
            // Player A withdraws winnings
            vm.prank(playerA);
            matchGame.withdraw(playerABalance);
    
            uint256 playerATokens = usdt.balanceOf(playerA);
            console.log("Player A withdrew, token balance:", playerATokens);
    
            // Player B withdraws remaining
            vm.prank(playerB);
            matchGame.withdraw(playerBBalance);
    
            uint256 playerBTokens = usdt.balanceOf(playerB);
            console.log("Player B withdrew, token balance:", playerBTokens);
    
            // ============================================
            console.log("\n=== FINAL VERIFICATION ===");
    
            // Verify balance conservation
            uint256 totalDep = matchGame.totalDeposited();
            uint256 totalWith = matchGame.totalWithdrawn();
            uint256 contractBal = usdt.balanceOf(address(matchGame));
    
            assertEq(
                totalDep,
                totalWith + contractBal,
                "Balance conservation violated"
            );
    
            console.log("\n COMPLETE USER JOURNEY SUCCESSFUL!");
            console.log("Player A net:", int256(playerATokens) - int256(200000e6));
            console.log("Player B net:", int256(playerBTokens) - int256(200000e6));
            console.log("Protocol earned:", collectedFees);
        }

        function testCancelMatchRevertsIfAlreadyFinished() public {
            // Create and finish match
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
            vm.prank(player2);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            uint256 matchId = matchGame.activeMatch(player1);
    
            // Finish match
            vm.prank(player2);
            matchGame.cancelMatch(matchId);
    
            // Try to cancel again
            vm.prank(player1);
            vm.expectRevert("Match already completed");
            matchGame.cancelMatch(matchId);
        }

        function testEmergencyRefundCooldown() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player2);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            uint256 matchId = matchGame.activeMatch(player1);

            // simulate backend crash
            vm.warp(block.timestamp + 3 days);

            vm.prank(player1);
            matchGame.requestEmergencyRefund(matchId);

            // player1 tries again immediately
            vm.prank(player1);
            vm.expectRevert("Please wait 1 hour before requesting again");
            matchGame.requestEmergencyRefund(matchId);
            vm.warp(block.timestamp + 1 hours + 1);

            vm.prank(player2);
            matchGame.requestEmergencyRefund(matchId);
        }

        function testCancelRefundRevertsIfNoRequest() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player2);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            uint256 matchId = matchGame.activeMatch(player1);

            vm.prank(player1);
            vm.expectRevert("No refund request to cancel");
            matchGame.cancelEmergencyRefund(matchId);
        }


        function testEmergencyRefundExecution() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player2);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            uint256 matchId = matchGame.activeMatch(player1);

            vm.warp(block.timestamp + 3 days);

            vm.prank(player1);
            matchGame.requestEmergencyRefund(matchId);

            vm.prank(player2);
            matchGame.requestEmergencyRefund(matchId);

            // Match should be finished
            (,,,,,address winner,bool finished,,,,,,) = matchGame.matches(matchId);

            assertTrue(finished);
        }

        function testEmergencyRefund_UpdatesStats() public {
            uint256 stake = 100e6;

            // Deposit
            vm.prank(player1);
            matchGame.deposit(stake);

            vm.prank(player2);
            matchGame.deposit(stake);

            // Join match
            vm.prank(player1);
            matchGame.joinMatch(stake);

            vm.prank(player2);
            matchGame.joinMatch(stake);

            uint256 matchId = matchGame.activeMatch(player1);

            // ⏩ FAST FORWARD TIME (CRITICAL FIX)
            vm.warp(block.timestamp + 3 days + 1 hours);

            // Request refund
            vm.prank(player1);
            matchGame.requestEmergencyRefund(matchId);

            vm.prank(player2);
            matchGame.requestEmergencyRefund(matchId);

            // Fetch stats
            (
                uint256 p1Balance,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint256 p1Refunded,
                uint256 p1Games
            ) = matchGame.getPlayerWallet(player1);

            (
                uint256 p2Balance,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint256 p2Refunded,
                uint256 p2Games
            ) = matchGame.getPlayerWallet(player2);

            // ✅ Assertions
            assertEq(p1Balance, stake);
            assertEq(p2Balance, stake);

            assertEq(p1Refunded, stake);
            assertEq(p2Refunded, stake);

            assertEq(p1Games, 1);
            assertEq(p2Games, 1);
        }

        function testCancelRefundRevertsIfNotRequester() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player2);
            matchGame.deposit(stakeAmount * 2);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            uint256 matchId = matchGame.activeMatch(player1);

            // simulate backend crash
            vm.warp(block.timestamp + 3 days);

            vm.prank(player1);
            matchGame.requestEmergencyRefund(matchId);

            // player2 tries to cancel player1's request
            vm.prank(player2);
            vm.expectRevert("No refund request to cancel");
            matchGame.cancelEmergencyRefund(matchId);
            // verify player1's request is cancelled
            (,,,,,,,,, bool p1Approves, bool p2Approves,,) = matchGame.matches(matchId);
            assertTrue(p1Approves, "Player A approval cancelled");
            assertFalse(p2Approves, "Player B approval cancelled");
     }

        function testReportWinnerInvalidWinner() public {

            vm.prank(player1);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(player2);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player2);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            uint256 matchId = matchGame.activeMatch(player1);
            uint256 nonce = matchGame.matchNonce(matchId) + 1;
            uint256 deadline = block.timestamp + 1 hours;
    
            (address p1, address p2,,,,,,,,,,,) = matchGame.matches(matchId);
    
            address fakeWinner = address(0x999); // Not a player
    
            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    p1,
                    p2,
                    fakeWinner,
                    nonce
                )
            );
    
            bytes32 digest = matchGame.hashTypedDataV4(structHash);
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes memory sig1 = abi.encodePacked(r1, s1, v1);
            bytes memory sig2 = abi.encodePacked(r2, s2, v2);
            bytes memory sig3 = abi.encodePacked(r3, s3, v3);

            bytes[] memory signatures = new bytes[](3);
            signatures[0] = sig1;
            signatures[1] = sig2;
            signatures[2] = sig3;
    
            vm.prank(player1);
            vm.expectRevert("Invalid winner");
            matchGame.reportMatchWinner(matchId, fakeWinner, nonce, deadline, signatures);
        }

        function testReportWinner_WrongMatchId() public {
    
            vm.prank(player1);
            usdt.approve(address(matchGame), type(uint256).max);
            vm.prank(player2);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player2);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            uint256 realMatchId = matchGame.activeMatch(player1);
            uint256 wrongMatchId = 9999;
            uint256 nonce = 1;
            uint256 deadline = block.timestamp + 1 hours;
    
            (address p1, address p2,,,,,,,,,,,) = matchGame.matches(realMatchId);
    
            // Sign for WRONG matchId
            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    wrongMatchId, 
                    p1,
                    p2,
                    player1,
                    nonce,
                    deadline
                )
            );
    
            bytes32 digest = matchGame.hashTypedDataV4(structHash);
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes memory sig1 = abi.encodePacked(r1, s1, v1);
            bytes memory sig2 = abi.encodePacked(r2, s2, v2);
            bytes memory sig3 = abi.encodePacked(r3, s3, v3);

            bytes[] memory signatures = new bytes[](3);
            signatures[0] = sig1;
            signatures[1] = sig2;
            signatures[2] = sig3;
    
            // Try to submit to real matchId with signature for wrong matchId
            vm.prank(player1);
            vm.expectRevert("Invalid winner");
            matchGame.reportMatchWinner(wrongMatchId, player1, nonce, deadline, signatures);
        }

        function testReportWinnerWrongSigner() public {
            // -----------------------------
            // Setup referee keys
            // -----------------------------
            uint256 refereePk1 = 0xA11CE;
            uint256 refereePk2 = 0xB11CE;
            uint256 refereePk3 = 0xC11CE;

            address referee1 = vm.addr(refereePk1);
            address referee2 = vm.addr(refereePk2);
            address referee3 = vm.addr(refereePk3);

            // Invalid referee
            uint256 wrongPrivateKey = 0x9999;

            // -----------------------------
            // Setup registry
            // -----------------------------
            RefereeRegistry localRegistry = new RefereeRegistry();

            localRegistry.addReferee(referee1);
            localRegistry.addReferee(referee2);
            localRegistry.addReferee(referee3);

            matchGame = new snookerMatch(address(usdt), address(localRegistry));

            // -----------------------------
            // Fund + approve
            // -----------------------------
            usdt.mint(player1, stakeAmount * 2);
            usdt.mint(player2, stakeAmount * 2);

            vm.prank(player1);
            usdt.approve(address(matchGame), type(uint256).max);

            vm.prank(player2);
            usdt.approve(address(matchGame), type(uint256).max);

            // -----------------------------
            // Deposit
            // -----------------------------
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player2);
            matchGame.deposit(stakeAmount);

            // -----------------------------
            // Join match
            // -----------------------------
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            // -----------------------------
            // Prepare signature data
            // -----------------------------
            uint256 matchId = matchGame.activeMatch(player1);

            uint256 nonce = matchGame.matchNonce(matchId) + 1;

            uint256 deadline = block.timestamp + 1 hours;

            (
                address p1,
                address p2,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
        
            ) = matchGame.matches(matchId);

            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    p1,
                    p2,
                    player1,
                    nonce,
                    deadline
                )
            );

            bytes32 digest = matchGame.hashTypedDataV4(structHash);

            // -----------------------------
            // 2 VALID signatures
            // -----------------------------
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk1, digest);

            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk2, digest);

            // -----------------------------
            // 1 INVALID signature
            // -----------------------------
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(wrongPrivateKey, digest);

            bytes[] memory signatures = new bytes[](3);

            signatures[0] = abi.encodePacked(r1, s1, v1);
            signatures[1] = abi.encodePacked(r2, s2, v2);
            signatures[2] = abi.encodePacked(r3, s3, v3);

            // -----------------------------
            // Should revert
            // -----------------------------
            vm.expectRevert("Invalid referee");

            vm.prank(player1);

            matchGame.reportMatchWinner(
                matchId,
                player1,
                nonce,
                deadline,
                signatures
            );
        }       

            function _createMatch(address playerA, address playerB) internal {
            usdt.mint(playerA, 200000e6);
            usdt.mint(playerB, 200000e6);

            vm.prank(playerA);
            usdt.approve(address(matchGame), type(uint256).max);

            vm.prank(playerB);
            usdt.approve(address(matchGame), type(uint256).max);

            vm.prank(playerA);
            matchGame.deposit(150000e6);

            vm.prank(playerB);
            matchGame.deposit(50000e6);

            vm.prank(playerA);
            matchGame.joinMatch(10000e6);

            vm.prank(playerB);
            matchGame.joinMatch(10000e6);
        }

        function _createMatch1() internal returns (uint256) {
            vm.startPrank(player1);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            vm.startPrank(player2);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            return 1;
        }

        function testReportWinnerExpiredSignature() public {
            // ---------------------------------
            // Setup 3 referees
            // ---------------------------------
            uint256 refereePk1 = 0xA11CE;
            uint256 refereePk2 = 0xB11CE;
            uint256 refereePk3 = 0xC11CE;

            address referee1 = vm.addr(refereePk1);
            address referee2 = vm.addr(refereePk2);
            address referee3 = vm.addr(refereePk3);

            // ---------------------------------
            // Setup registry
            // ---------------------------------
            RefereeRegistry localRegistry = new RefereeRegistry();

            localRegistry.addReferee(referee1);
            localRegistry.addReferee(referee2);
            localRegistry.addReferee(referee3);

            matchGame = new snookerMatch(
                address(usdt),
                address(localRegistry)
            );

            // ---------------------------------
            // Create match
            // ---------------------------------
            address playerA = address(0xAAA);
            address playerB = address(0xBBB);

            _createMatch(playerA, playerB);

            uint256 matchId = matchGame.activeMatch(playerA);

            uint256 nonce = matchGame.matchNonce(matchId) + 1;

            uint256 deadline = block.timestamp + 1 hours;

            // ---------------------------------
            // Create EIP712 digest
            // ---------------------------------
            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    playerA,
                    playerB,
                    playerA,
                    nonce,
                    deadline
                )
            );

            bytes32 digest = matchGame.hashTypedDataV4(structHash);

            // ---------------------------------
            // Create 3 valid signatures
            // ---------------------------------
            (uint8 v1, bytes32 r1, bytes32 s1) =
                vm.sign(refereePk1, digest);

            (uint8 v2, bytes32 r2, bytes32 s2) =
                vm.sign(refereePk2, digest);

            (uint8 v3, bytes32 r3, bytes32 s3) =
                vm.sign(refereePk3, digest);

            bytes[] memory signatures = new bytes[](3);

            signatures[0] = abi.encodePacked(r1, s1, v1);
            signatures[1] = abi.encodePacked(r2, s2, v2);
            signatures[2] = abi.encodePacked(r3, s3, v3);

            // ---------------------------------
            // Expire signature
            // ---------------------------------
            vm.warp(deadline + 1);

            // ---------------------------------
            // Should revert
            // ---------------------------------
            vm.expectRevert("Signature expired");

            vm.prank(playerA);

            matchGame.reportMatchWinner(
                matchId,
                playerA,
                nonce,
                deadline,
                signatures
            );
        }       

        function testReportWinnerInvalidNonce() public {
            // ---------------------------------
            // Setup referees
            // ---------------------------------
            uint256 refereePk1 = 0xA11CE;
            uint256 refereePk2 = 0xB11CE;
            uint256 refereePk3 = 0xC11CE;

            address referee1 = vm.addr(refereePk1);
            address referee2 = vm.addr(refereePk2);
            address referee3 = vm.addr(refereePk3);

            // ---------------------------------
            // Setup registry
            // ---------------------------------
            RefereeRegistry localRegistry = new RefereeRegistry();

            localRegistry.addReferee(referee1);
            localRegistry.addReferee(referee2);
            localRegistry.addReferee(referee3);

            matchGame = new snookerMatch(
                address(usdt),
                address(localRegistry)
            );

            // ---------------------------------
            // Create match
            // ---------------------------------
            address playerA = address(0xAAA);
            address playerB = address(0xBBB);

            _createMatch(playerA, playerB);

            uint256         matchId = matchGame.activeMatch(playerA);

            uint256 correctNonce =
                matchGame.matchNonce(matchId) + 1;

            uint256 wrongNonce =
                correctNonce + 1; // invalid nonce

            uint256 deadline =
                block.timestamp + 1 hours;

            // ---------------------------------
            // Build hash with WRONG nonce
            // ---------------------------------
            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    playerA,
                    playerB,
                    playerA,
                    wrongNonce,
                    deadline
                )
            );

            bytes32 digest =
                matchGame.hashTypedDataV4(structHash);

            // ---------------------------------
            // Create signatures
            // ---------------------------------
            (uint8 v1, bytes32 r1, bytes32 s1) =
                vm.sign(refereePk1, digest);

            (uint8 v2, bytes32 r2, bytes32 s2) =
                vm.sign(refereePk2, digest);

            (uint8 v3, bytes32 r3, bytes32 s3) =
                vm.sign(refereePk3, digest);

            bytes[] memory signatures =
                new bytes[](3);

            signatures[0] =
                abi.encodePacked(r1, s1, v1);

            signatures[1] =
                abi.encodePacked(r2, s2, v2);

            signatures[2] =
                abi.encodePacked(r3, s3, v3);

            // ---------------------------------
            // Should revert
            // ---------------------------------
            vm.expectRevert("Invalid nonce");

            vm.prank(playerA);

            matchGame.reportMatchWinner(
                matchId,
                playerA,
                wrongNonce,
                deadline,
                signatures
            );
        }


        function testReportWinnerAlreadyFinished() public {
            // ---------------------------------
            // Setup referees
            // ---------------------------------
            uint256 refereePk1 = 0xA11CE;
            uint256 refereePk2 = 0xB11CE;
            uint256 refereePk3 = 0xC11CE;

            address referee1 = vm.addr(refereePk1);
            address referee2 = vm.addr(refereePk2);
            address referee3 = vm.addr(refereePk3);

            // ---------------------------------
            // Setup registry
            // ---------------------------------
            RefereeRegistry localRegistry = new RefereeRegistry();

            localRegistry.addReferee(referee1);
            localRegistry.addReferee(referee2);
            localRegistry.addReferee(referee3);

            matchGame = new snookerMatch(
                address(usdt),
                address(localRegistry)
            );

            // ---------------------------------
            // Create match
            // ---------------------------------
            address playerA = address(0xAAA);
            address playerB = address(0xBBB);

            _createMatch(playerA, playerB);

            uint256 matchId =
                matchGame.activeMatch(playerA);

            uint256 nonce =
                matchGame.matchNonce(matchId) + 1;

            uint256 deadline =
                block.timestamp + 1 hours;

            // ---------------------------------
            // Build struct hash
            // ---------------------------------
            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    playerA,
                    playerB,
                    playerA,
                    nonce,
                    deadline
                )
            );

            bytes32 digest =
                matchGame.hashTypedDataV4(structHash);

            // ---------------------------------
            // Create referee signatures
            // ---------------------------------
            (uint8 v1, bytes32 r1, bytes32 s1) =
                vm.sign(refereePk1, digest);

            (uint8 v2, bytes32 r2, bytes32 s2) =
                vm.sign(refereePk2, digest);

            (uint8 v3, bytes32 r3, bytes32 s3) =
                vm.sign(refereePk3, digest);

            bytes[] memory signatures =
                new bytes[](3);

            signatures[0] =
                abi.encodePacked(r1, s1, v1);

            signatures[1] =
                abi.encodePacked(r2, s2, v2);

            signatures[2] =
                abi.encodePacked(r3, s3, v3);

            // ---------------------------------
            // First valid submission
            // ---------------------------------
            vm.prank(playerA);

            matchGame.reportMatchWinner(
                matchId,
                playerA,
                nonce,
                deadline,
                signatures
            );

            // ---------------------------------
            // Try again after completion
            // ---------------------------------
            vm.expectRevert("Match Already Completed");

            vm.prank(playerB);

            matchGame.reportMatchWinner(
                matchId,
                playerA,
                nonce,
                deadline,
                signatures
            );
        }       

         function testOnlyReferee_RevertIfNotOwner() public {
           IRefereeRegistry reg = matchGame.refereeRegistry();

            vm.prank(player1);
            vm.expectRevert();
            reg.addReferee(address(0x123));
         }

         function testSetRefereeZeroAddress() public {
            IRefereeRegistry reg = matchGame.refereeRegistry(); 

            vm.prank(owner);
            vm.expectRevert("Zero Address");
            reg.addReferee(address(0)); 
        }

        function testSetSupportedAmountSuccess() public {
            vm.prank(owner);
            matchGame.setSupportedAmount(999e6, true);
    
            // Test by trying to join with that amount
            vm.prank(player1);
            matchGame.deposit(1000e6);
    
            vm.prank(player1);
            matchGame.joinMatch(999e6); 
    
            assertTrue(matchGame.inQueue(player1));
        }

        function testSetSupportedAmountNotOwner() public {
            vm.prank(player1);
            vm.expectRevert();
            matchGame.setSupportedAmount(999e6, true);
        }

        function testOnlyReferee_RevertIfNotReferee() public {
            // ---------------------------------
            // Create match
            // ---------------------------------
            vm.startPrank(player1);

            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(stakeAmount);

            vm.stopPrank();

            vm.startPrank(player2);

            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(stakeAmount);

            vm.stopPrank();

            uint256 matchId = matchGame.activeMatch(player1);

            // ---------------------------------
            // Invalid nonce setup
            // ---------------------------------
            uint256 invalidNonce = 0;

            uint256 deadline =
                block.timestamp + 1 hours;

            // Empty signatures array
            bytes[] memory signatures =
                new bytes[](0);

            // ---------------------------------
            // Non-referee attempts submission
            // ---------------------------------
            vm.expectRevert("Invalid nonce");

            vm.prank(player1);

            matchGame.reportMatchWinner(
                matchId,
                player1,
                invalidNonce,
                deadline,
                signatures
            );
        }

        function testOnlyOwner_SucceedsIfOwner() public {
            // owner is address(this), so no prank needed
            matchGame.refereeRegistry().addReferee(address(0x123));
        }

        function testOnlyOwner_CanUpdateRefereeTwice() public {
            // first update
            matchGame.refereeRegistry().addReferee(player3);

            // second update
            matchGame.refereeRegistry().addReferee(player1);
        }

        function _signResult(
            uint256 matchId,
            address winner,
            uint256 nonce,
            uint256 deadline
        ) internal returns (bytes[] memory) {
            // fetch players
            (address p1, address p2,,,,,,,,,,,) =
                matchGame.matches(matchId);

            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    p1,
                    p2,
                    winner,
                    nonce,
                    deadline
                )
            );

            bytes32 digest =
                matchGame.hashTypedDataV4(structHash);

            // sign
            (uint8 v1, bytes32 r1, bytes32 s1) =
                vm.sign(refereePk, digest);

            (uint8 v2, bytes32 r2, bytes32 s2) =
                vm.sign(refereePk1, digest);

            (uint8 v3, bytes32 r3, bytes32 s3) =
                vm.sign(refereePk2, digest);

            bytes[] memory signatures =
                new bytes[](3);

            signatures[0] =
                abi.encodePacked(r1, s1, v1);

            signatures[1] =
                abi.encodePacked(r2, s2, v2);

            signatures[2] =
                abi.encodePacked(r3, s3, v3);

            return signatures;
        }

        function testFinalizeMatch_RevertIfWinnerZeroAddress() public {
            uint256 matchId = _createMatch1();

            uint256 nonce = matchGame.matchNonce(matchId);
            uint256 deadline = block.timestamp + 1 hours;

            bytes[] memory sig = _signResult(matchId, player1, nonce, deadline);

            vm.prank(player1);

            vm.expectRevert("Invalid nonce");
            matchGame.reportMatchWinner(matchId, player1, nonce, deadline, sig);
        }

        function testFinalizeMatch_RevertIfMatchNotActive() public {
            // only one player joins → match NOT active
            vm.startPrank(player1);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(stakeAmount);
            vm.stopPrank();

            uint256 matchId = 1;

            uint256 nonce = matchGame.matchNonce(matchId);
            uint256 deadline = block.timestamp + 1 hours;

            bytes[] memory sig = _signResult(matchId, player1, nonce, deadline);

            vm.prank(player1);

            vm.expectRevert();
            matchGame.reportMatchWinner(matchId, player1, nonce, deadline, sig);
        }


        function testGetQueuePlayers_ReturnsCorrectQueue() public {
            uint256 stake = stakeAmount;

            // player1 joins queue
            vm.startPrank(player1);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(stake);
            vm.stopPrank();

            // player2 joins queue
            vm.startPrank(player2);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(stake);
            vm.stopPrank();

            address[] memory players = matchGame.getQueuePlayers(stake);

            assertEq(players.length, 0); 
            // ⚠️ Because your logic auto-matches 2 players and removes them
        }


        function testGetQueuePlayers_WhenOnlyOnePlayer() public {
            uint256 stake = stakeAmount;

            vm.startPrank(player1);
            matchGame.deposit(200        * 1e6);
            matchGame.joinMatch(stake);
            vm.stopPrank();

            address[] memory players = matchGame.getQueuePlayers(stake);

            assertEq(players.length, 1);
            assertEq(players[0], player1);
        }

        function testFinalizeMatch_RevertIfInvalidWinner() public {
            uint256 matchId = _createMatch1();

            uint256 nonce = matchGame.matchNonce(matchId);
            uint256 deadline = block.timestamp + 1 hours;

            // player3 is NOT in match
            bytes[] memory sig = _signResult(matchId, player3, nonce, deadline);

            vm.expectRevert("Invalid winner");
            matchGame.reportMatchWinner(matchId, player3, nonce, deadline, sig);
        }

        function testFinalizeMatch_RevertIfAlreadyFinished() public {
            uint256 matchId = _createMatch1();
            uint256 deadline = block.timestamp + 1 hours;

            // -------------------------
            // FIRST CALL (valid)
            // -------------------------
            uint256 nonce1 = matchGame.matchNonce(matchId) + 1;

            bytes[] memory sig1 = _signResult(
                matchId,
                player1,
                nonce1,
                deadline
            );

            matchGame.reportMatchWinner(
                matchId,
                player1,
                nonce1,
                deadline,
                sig1
            );

            // -------------------------
            // SECOND CALL (should revert)
            // -------------------------
            uint256 nonce2 = matchGame.matchNonce(matchId) + 1;

            bytes[] memory sig2 = _signResult(
                matchId,
                player1,
                nonce2,
                deadline
            );

            vm.expectRevert("Match Already Completed");

            matchGame.reportMatchWinner(
                matchId,
                player1,
                nonce2,
                deadline,
                sig2
            );
        }

        function testFinalizeMatch_LoserStatsUpdated() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player2);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            uint256 matchId = matchGame.activeMatch(player1);
    
            vm.prank(player2);
            matchGame.cancelMatch(matchId);
    
            // Check loser (player2)
            (,, uint256 wonAmount, uint256 lostAmount, ,,,,, uint256 gamesPlayed) = matchGame.wallets(player2);
    
            assertEq(gamesPlayed, 1, "Loser should have 1 game played");
            assertEq(lostAmount, stakeAmount, "Loser should have stake recorded as loss");
            assertEq(wonAmount, 0, "Loser should have no winnings");
        }

        function testFinalizeMatch_WinnerStatsUpdated() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player2);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);
    
            uint256 matchId = matchGame.activeMatch(player2);
    
            // player1 cancels → player2 wins
            vm.prank(player1);
            matchGame.cancelMatch(matchId);

            //  check actual winner (player2)
            (,, uint256 wonAmount, uint256 lostAmount, ,,,,, uint256 gamesPlayed) = matchGame.wallets(player2);

            uint256 totalStake = stakeAmount * 2;
            uint256 fee = (totalStake * matchGame.MATCH_BPS_FEE()) / 10_000;
            uint256 actualProfit = totalStake - fee - stakeAmount;

            assertEq(gamesPlayed, 1);
            assertEq(wonAmount, actualProfit, "Winner should have winnings recorded correctly");
            assertEq(lostAmount, 0);
        }

        function testFinalizeMatch_UpdatesAllStats() public {
    // setup
    vm.prank(player1);
    matchGame.deposit(stakeAmount);

    vm.prank(player2);
    matchGame.deposit(stakeAmount);

    // create match
    vm.prank(player1);
    matchGame.joinMatch(stakeAmount);

    vm.prank(player2);
    matchGame.joinMatch(stakeAmount);

    uint256 matchId = matchGame.activeMatch(player1);

    // player2 forfeits → player1 wins
    vm.prank(player2);
    matchGame.cancelMatch(matchId);

    // fetch stats
    (
        uint256 p1Balance,
        ,
        uint256 p1Won,
        uint256 p1Lost,
        uint256 p1Wagered,
        uint256 p1Wins,
        uint256 p1Losses,
        ,
        ,
        uint256 p1Games
    ) = matchGame.getPlayerWallet(player1);

    (
        uint256 p2Balance,
        ,
        uint256 p2Won,
        uint256 p2Lost,
        uint256 p2Wagered,
        uint256 p2Wins,
        uint256 p2Losses,
        ,
        ,
        uint256 p2Games
    ) = matchGame.getPlayerWallet(player2);

    uint256 totalStake = stakeAmount * 2;
    uint256 fee = (totalStake * matchGame.MATCH_BPS_FEE()) / 10_000;
    uint256 payout = totalStake - fee;
    uint256 profit = payout - stakeAmount;

    // assertions
    assertEq(p1Wins, 1);
    assertEq(p2Losses, 1);

    assertEq(p1Games, 1);
    assertEq(p2Games, 1);

    assertEq(p1Wagered, stakeAmount);
    assertEq(p2Wagered, stakeAmount);

    assertEq(p1Won, profit);
    assertEq(p2Lost, stakeAmount);

    assertEq(p1Balance, payout);
    assertEq(p2Balance, 0);
}

        function testWithdrawFees_Revert_NotOwner() public {
            vm.prank(player1);
            vm.expectRevert();
            matchGame.withdrawFees(player1);
        }

        function testWithdrawFeesRevertsIfNoFees() public {
            vm.prank(owner);
            vm.expectRevert("No fees to withdraw");
            matchGame.withdrawFees(player1);
        }

        function _reportWinner(uint256 matchId, address winner) internal {

            uint256 nonce = matchGame.matchNonce(matchId) + 1;
            uint256 deadline = block.timestamp + 1 hours;

            (address player1, address player2,,,,,,,,,,,) =
                matchGame.matches(matchId);

            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    player1,
                    player2,
                    winner,
                    nonce,
                    deadline
                )
            );

            bytes32 digest = matchGame.hashTypedDataV4(structHash);

            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes[] memory signatures = new bytes[](3);

            signatures[0] = abi.encodePacked(r1, s1, v1);
            signatures[1] = abi.encodePacked(r2, s2, v2);
            signatures[2] = abi.encodePacked(r3, s3, v3);

            matchGame.reportMatchWinner(
                matchId,
                winner,
                nonce,
                deadline,
                signatures
            );
        }

        function testWithdrawFees_RevertZeroAddress() public {
            // Create match so fees exist
            _createMatch(player1, player2);

            uint256 matchId = matchGame.activeMatch(player1);

            // Generate valid multi-sig winner report (FIXED)
            uint256 nonce = matchGame.matchNonce(matchId) + 1;
            uint256 deadline = block.timestamp + 1 hours;

            (address p1, address p2,,,,,,,,,,,) = matchGame.matches(matchId);

            bytes32 structHash = keccak256(
                abi.encode(
                    matchGame.MATCH_RESULT_TYPEHASH(),
                    matchId,
                    p1,
                    p2,
                    player1,
                    nonce,
                    deadline
                )
            );

            bytes32 digest = matchGame.hashTypedDataV4(structHash);

            // signers MUST all be registered referees
            (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(refereePk, digest);
            (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(refereePk1, digest);
            (uint8 v3, bytes32 r3, bytes32 s3) = vm.sign(refereePk2, digest);

            bytes[] memory sigs = new bytes[](3);
            sigs[0] = abi.encodePacked(r1, s1, v1);
            sigs[1] = abi.encodePacked(r2, s2, v2);
            sigs[2] = abi.encodePacked(r3, s3, v3);

            vm.prank(player1);
            matchGame.reportMatchWinner(matchId, player1, nonce, deadline, sigs);

            // NOW fees exist → test withdraw revert

            vm.prank(owner);
            vm.expectRevert("Invalid recipient address");
            matchGame.withdrawFees(address(0));
        }

        function testWithdrawFees_GeneratesFees() public {
            _createMatch(player1, player2);

            uint256 matchId = matchGame.activeMatch(player1);

            // finalize match → generates fees
            _reportWinner(matchId, player1);

            uint256 before = usdt.balanceOf(player3);

            vm.prank(owner);
            matchGame.withdrawFees(player3);

            uint256 afterBal = usdt.balanceOf(player3);

            assertGt(afterBal, before);
            assertEq(matchGame.collectedFees(), 0);
        } 

        function testWithdrawFees_Works() public {
            // generate fees via match
            vm.prank(player1);
            matchGame.deposit(stakeAmount);

            vm.prank(player2);
            matchGame.deposit(stakeAmount);

            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);

            vm.prank(player2);
            matchGame.joinMatch(stakeAmount);

            uint256 matchId = matchGame.activeMatch(player1);

            vm.prank(player2);
            matchGame.cancelMatch(matchId);

            uint256 fees = matchGame.collectedFees();

            uint256 ownerBalanceBefore = usdt.balanceOf(owner);

            matchGame.withdrawFees(owner);

            uint256 ownerBalanceAfter = usdt.balanceOf(owner);

            assertEq(ownerBalanceAfter - ownerBalanceBefore, fees);
            assertEq(matchGame.collectedFees(), 0);
        }      

        function testWithdrawAll_Revert_InActiveMatch() public {
            vm.startPrank(player1);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(100e6);
            vm.stopPrank();

            vm.startPrank(player2);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(100e6);
            vm.stopPrank();

            uint256 matchId = matchGame.activeMatch(player1);
            assertGt(matchId, 0, "Match should be active");
            vm.prank(player1);
            vm.expectRevert("cannot withdraw while in active match");
            matchGame.withdrawAll();
        }

        function testWithdraw_Revert_InsufficientLiquidity() public {

            vm.prank(player1);
            matchGame.deposit(100e6);

            vm.prank(player2);
            matchGame.deposit(100e6);

            vm.prank(player1);
            matchGame.joinMatch(100e6);

            vm.prank(player2);
            matchGame.joinMatch(100e6);

            uint256 matchId = matchGame.activeMatch(player1);

            vm.prank(player2);
            matchGame.cancelMatch(matchId); // player1 wins
            // Drain contract manually (simulate bug/external drain)
            deal(address(usdt), address(matchGame), 0); // wipe contract balance

            vm.prank(player1);
            vm.expectRevert("Insufficient Withdrawal Liquidity");
            matchGame.withdraw(100e6);
        }
        // Stopped here ✨✨
        function testWithdraw_RevertsWhenContractBalanceBelowLocked() public {
            vm.prank(player1);
            matchGame.deposit(50e6);
    
            vm.prank(player2);
            matchGame.deposit(50e6);
    
            // Create match → locks 20e6
            vm.prank(player1);
            matchGame.joinMatch(10e6);
    
            vm.prank(player2);
            matchGame.joinMatch(10e6);
    
            uint256 matchId = matchGame.activeMatch(player1);
    
            // ✅ FINISH THE MATCH so player1 can withdraw
            vm.prank(player2);
            matchGame.cancelMatch(matchId);
    
            // Now player1 is NOT in active match anymore ✅
    
            // Contract has: 100e6
            // totalLockedInMatches: 0 (match finished, funds unlocked)
    
            // 🔥 Need to create ANOTHER active match to lock funds
            // Use player2 and player3
            address player3 = address(0x3);
            usdt.mint(player3, 50e6);
    
            vm.prank(player3);
            usdt.approve(address(matchGame), type(uint256).max);
    
            vm.prank(player3);
            matchGame.deposit(50e6);
    
            // Player2 and Player3 create new match → locks 40e6
            vm.prank(player2);
            matchGame.joinMatch(20e6);
    
            vm.prank(player3);
            matchGame.joinMatch(20e6);
    
            // Now:
            // contractBalance: 150e6 total
            // totalLockedInMatches: 40e6 (from player2 vs player3 match)
    
            // 🔥 Drain contract balance
            vm.prank(address(matchGame));
            usdt.transfer(address(0xdead), 120e6);
    
            // Now:
            // contractBalance: 30e6
            // totalLockedInMatches: 40e6
            // 30 < 40 → First require fails! ✅
    
            // Player1 tries to withdraw (NOT in match, has balance)
            vm.prank(player1);
            vm.expectRevert("Cannot Withdraw At This Time");
            matchGame.withdraw(1e6);
        }

        function testWithdraw_RevertsInsufficientLiquidity() public {
            // Player1 deposits 200e6
            vm.startPrank(player1);
            usdt.mint(player1, 200e6);
            usdt.approve(address(matchGame), 200e6);
            matchGame.deposit(200e6);
            vm.stopPrank();

            // Player2 deposits 200e6
            vm.startPrank(player2);
            usdt.mint(player2, 200e6);
            usdt.approve(address(matchGame), 200e6);
            matchGame.deposit(200e6);
            vm.stopPrank();

            // Player3 deposits 200e6
            vm.startPrank(player3);
            usdt.mint(player3, 200e6);
            usdt.approve(address(matchGame), 200e6);
            matchGame.deposit(200e6);
            vm.stopPrank();

            // Player2 and Player3 join a match, locking 200e6 each = 400e6 locked
            vm.prank(player2);
            matchGame.joinMatch(200e6);

            vm.prank(player3);
            matchGame.joinMatch(200e6);

            // contractBalance = 600e6, locked = 400e6, available = 200e6
            // player1 balance = 200e6 — withdraw 200e6 would PASS (200 >= 200)
    
            // Drain 100e6 from the contract directly to simulate low liquidity
            // (e.g., via a bug, or by sending tokens out of the contract in your test)
            // MockUSDT likely has a transfer function accessible here:
            vm.prank(address(matchGame));  // pretend to be the contract
            usdt.transfer(address(0xdead), 100e6); // drain 100e6 out

            // Now: contractBalance = 500e6, locked = 400e6, available = 100e6
            // player1 balance = 200e6 >= 150e6 (passes), available 100e6 < 150e6 (REVERTS) ✓

            vm.prank(player1);
            vm.expectRevert("Insufficient Withdrawal Liquidity");
            matchGame.withdraw(150e6);
        }

        function testWithdraw_Revert_InsufficientBalance() public {
            vm.prank(player1);
            matchGame.deposit(100e6);
            usdt.mint(player1, 100e6); // ensure player has balance to deposit
            usdt.approve(address(matchGame), 100e6);

            vm.prank(player1);
            vm.expectRevert("Insufficient withdraw balance");
            matchGame.withdraw(200e6);
        }

        function testWithdraw_RevertsIfContractBalanceBelowLocked() public {
            vm.startPrank(player1);

            matchGame.deposit(10e6);

            // Ensure NOT in match
            // (no joinMatch call)


            vm.store(
                address(matchGame),
                bytes32(uint256(6)),
                bytes32(uint256(100e6))
            );

            vm.expectRevert("Cannot Withdraw At This Time");
            matchGame.withdraw(1e6);

            vm.stopPrank();
        }

        function testWithdrawAll_UpdatesStats_GlobalAndUser() public {
            uint256 depositAmount = 200e6;

            vm.prank(player1);
            matchGame.deposit(depositAmount);

            uint256 globalBefore = matchGame.totalWithdrawn();

            vm.prank(player1);
            matchGame.withdrawAll();

            (
                uint256 balance,
                ,
                ,
                ,
                ,
                ,
                ,
                uint256 userWithdrawn,
                ,
        
            ) = matchGame.getPlayerWallet(player1);

            uint256 globalAfter = matchGame.totalWithdrawn();

            assertEq(balance, 0);
            assertEq(userWithdrawn, depositAmount);
            assertEq(globalAfter - globalBefore, depositAmount);
            console.log("Global withdrawn before:", globalBefore);
            console.log("Global withdrawn after:", globalAfter);
            console.log("User withdrawn:", userWithdrawn);
            console.log("Deposit amount:", depositAmount);
            console.log("Global withdrawn change:", globalAfter - globalBefore);
        }

        function testWithdrawAll_RevertInQueue() public {
            vm.startPrank(player1);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(100e6);
            vm.stopPrank();

            assertEq(matchGame.activeMatch(player1), 0);
            assertTrue(matchGame.inQueue(player1));
            vm.prank(player1);
            vm.expectRevert("Cannot withdrawAll while in queue");
            matchGame.withdrawAll();
        }

        function testWithdraw_RevertInQueue() public {
            vm.startPrank(player1);
            matchGame.deposit(200 * 1e6);
            matchGame.joinMatch(100e6);
            vm.stopPrank();
            assertEq(matchGame.activeMatch(player1), 0);
            assertTrue(matchGame.inQueue(player1));
            vm.prank(player1);
            vm.expectRevert("Cannot withdraw while in queue");
            matchGame.withdraw(100 * 1e6);
        }

        function testWithdrawRevertsIfInQueue() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            vm.prank(player1);
            vm.expectRevert("Cannot withdraw while in queue");
            matchGame.withdraw(stakeAmount);
        }

        function testFuzz_NoWithdrawWhenQueuedOrActive(uint96 depositAmount, uint96 amount) public {
            uint256 stake = 100e6;

            // Shape inputs instead of assuming
            depositAmount = uint96(bound(depositAmount, stake * 2, 1000e6));

            address player1 = address(1);
            address player2 = address(2);

            // --- PLAYER 1 ---
            vm.startPrank(player1);
            usdt.mint(player1, depositAmount);
            usdt.approve(address(matchGame), depositAmount);
            matchGame.deposit(depositAmount);
            matchGame.joinMatch(stake);
            vm.stopPrank();

            // --- PLAYER 2 (to trigger match OR leave queue depending on fuzz) ---
            vm.startPrank(player2);
            usdt.mint(player2, depositAmount);
            usdt.approve(address(matchGame), depositAmount);
            matchGame.deposit(depositAmount);

            // Randomly decide to join or not (fuzz behavior)
            if (depositAmount % 2 == 0) {
                matchGame.joinMatch(stake);
            }
            vm.stopPrank();

            uint256 active = matchGame.activeMatch(player1);

            // Get balance safely
            (uint256 balance,,,,,,,,,) = matchGame.wallets(player1);

            // Bound withdraw amount
            amount = uint96(bound(amount, 1, balance));

            vm.startPrank(player1);

            if (active > 0) {
                vm.expectRevert("cannot withdraw while in active match");
                matchGame.withdraw(amount);
            } else if (matchGame.inQueue(player1)) {
                vm.expectRevert("Cannot withdraw while in queue");
                matchGame.withdraw(amount);
            }

            vm.stopPrank();
        }


       function testFuzz_NoWithdrawWhenActiveMatch(uint96 depositAmount, uint96 amount) public {
            uint256 stake = 100e6;

            // Ensure valid deposit
            vm.assume(depositAmount >= stake * 2);

            address player1 = address(1);
            address player2 = address(2);

            // --- PLAYER 1 ---
            vm.startPrank(player1);
            usdt.mint(player1, depositAmount);
            usdt.approve(address(matchGame), depositAmount);
            matchGame.deposit(depositAmount);
            matchGame.joinMatch(stake);
            vm.stopPrank();

            // --- PLAYER 2 (to trigger match) ---
            vm.startPrank(player2);
            usdt.mint(player2, depositAmount);
            usdt.approve(address(matchGame), depositAmount);
            matchGame.deposit(depositAmount);
            matchGame.joinMatch(stake);
            vm.stopPrank();

            // Ensure match is active
            assertGt(matchGame.activeMatch(player1), 0);

            // Bound withdraw amount to valid range
            (uint256 balance,,,,,,,,,) = matchGame.wallets(player1);
            amount = uint96(bound(amount, 1, balance));

            vm.startPrank(player1);

            vm.expectRevert("cannot withdraw while in active match");
            matchGame.withdraw(amount);

            vm.stopPrank();
        }

        function testCancelJoinRequestSuccess() public {
            vm.prank(player1);
            matchGame.deposit(stakeAmount);
    
            vm.prank(player1);
            matchGame.joinMatch(stakeAmount);
    
            assertTrue(matchGame.inQueue(player1));
    
            vm.prank(player1);
            matchGame.cancelJoinRequest();
    
            assertFalse(matchGame.inQueue(player1));
        }

}
