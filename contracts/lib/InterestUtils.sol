pragma solidity ^0.8.0;

// Use prefix "./" normally and "https://github.com/ogDAO/Governance/blob/master/contracts/" in Remix
import "./ABDKMathQuad.sol";
import "./ABDKMath64x64.sol";

/// @notice Interest calculation utilities
// SPDX-License-Identifier: GPLv2
contract InterestUtils {
    using ABDKMathQuad for bytes16;
    bytes16 immutable ten18 = ABDKMathQuad.fromUInt(10**18);
    bytes16 immutable days365 = ABDKMathQuad.fromUInt(365 days);
    bytes16 immutable hours24 = ABDKMathQuad.fromUInt(24 hours);

    /// @notice futureValue = presentValue x exp(rate% x termInYears)
    function futureValue(
        uint256 presentValue,
        uint256 from,
        uint256 to,
        uint256 rate
    ) internal view returns (uint256) {
        require(from <= to, "Invalid date range");
        bytes16 i = ABDKMathQuad.fromUInt(rate).div(ten18);
        bytes16 t = ABDKMathQuad.fromUInt(to - from).div(days365);
        bytes16 fv = ABDKMathQuad.fromUInt(presentValue).mul(
            ABDKMathQuad.exp(i.mul(t))
        );
        return fv.toUInt();
    }

    function fv(
        uint256 v,
        uint256 t,
        int128 dr,
        uint256 c
    ) external pure returns (uint256) {
        return
            uint256(
                ABDKMath64x64.mulu(
                    ABDKMath64x64.pow(
                        ABDKMath64x64.add(
                            0x10000000000000000,
                            ABDKMath64x64.div(dr, ABDKMath64x64.divu(c, t))
                        ),
                        c
                    ),
                    v
                )
            );
    }

    function pow(int128 x, uint256 n) public pure returns (int128 r) {
        r = ABDKMath64x64.fromUInt(1);
        while (n > 0) {
            if (n % 2 == 1) {
                r = ABDKMath64x64.mul(r, x);
                n -= 1;
            } else {
                x = ABDKMath64x64.mul(x, x);
                n /= 2;
            }
        }
    }

    function compound(
        uint256 principle,
        int128 rate,
        int128 periods
    ) external pure returns (uint256) {
        uint256 result = ABDKMath64x64.mulu(
            ABDKMath64x64.pow(
                ABDKMath64x64.add(0x10000000000000000, rate),
                ABDKMath64x64.toUInt(periods)
            ),
            principle
        );
        return result;
    }

    function fv2(int128 a, uint256 b) external pure returns (int128) {
        int128 result = ABDKMath64x64.pow(a, b);
        return result;
    }
}
