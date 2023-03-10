/*
    Copyright 2022 JOJO Exchange
    SPDX-License-Identifier: BUSL-1.1*/
pragma solidity 0.8.9;

import "../Impl/USDOBankInit.t.sol";
import "../../src/Interface/IUSDOBank.sol";
import "../../src/Interface/IFlashLoanReceive.sol";

contract MockFlashloan is IFlashLoanReceive {
    using SafeERC20 for IERC20;

    function JOJOFlashLoan(
        address asset,
        uint256 amount,
        address to,
        bytes calldata param
    ) external {
        address bob = 0x2f66c75A001Ba71ccb135934F48d844b46454543;
        address mockToken2 = 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f;
        address usdoBank = 0x15cF58144EF33af1e14b5208015d11F9143E27b9;
        IERC20(asset).safeTransfer(bob, amount);

        IUSDOBank(usdoBank).deposit(
            address(this),
            address(mockToken2),
            5e8,
            to
        );
    }
}
