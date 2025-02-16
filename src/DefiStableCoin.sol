// SPDX-License-Identifier: MIT
// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin
// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions
pragma solidity ^0.8.28;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DefiStableCoin is ERC20Burnable, Ownable {
    error DefiStableCoin__AmountMustBeMoreThanZero();
    error DefiStableCoin__BurnAmountExceedsBalance();
    error DefiStableCoin__NotZeroAddress();

    constructor() ERC20("DefiStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DefiStableCoin__AmountMustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DefiStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount); // 使用父级的方法
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DefiStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DefiStableCoin__AmountMustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
