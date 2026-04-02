// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {OnChainBlackjack} from "../src/OnChainBlackjack.sol";

contract OnChainBlackjackScript is Script {
    function run() external returns (OnChainBlackjack) {
        vm.startBroadcast();
        OnChainBlackjack blackjack = new OnChainBlackjack();
        console.log("Deployed at: ", address(blackjack));
        vm.stopBroadcast();
        return blackjack;
    }
}
