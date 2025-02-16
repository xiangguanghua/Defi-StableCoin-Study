// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DefiStableCoin} from "../../src/DefiStableCoin.sol";

contract Handler is Test {
    DSCEngine engine;
    DefiStableCoin dsc;

    constructor(DSCEngine _engine, DefiStableCoin _dsc) {
        engine = _engine;
        dsc = _dsc;
    }

    function depositCollateral(address collateral, uint256 amountCollateral) public {
        engine.depositCollateral(collateral, amountCollateral);
    }
}
