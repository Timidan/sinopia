// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library ResultJson {
    function parse(bytes calldata data)
        internal
        pure
        returns (bool valid, bytes32 imageHash, string memory jobId, bool rejectable)
    {
        uint256 i = _ws(data, 0);
        if (i == data.length || data[i] != "{") return (false, 0, "", false);
        i = _ws(data, i + 1);
        bool complete;
        bool completed;
        bool image;
        bool hashValid;
        uint256 jobStart;
        uint256 jobEnd;
        bool jobSeen;
        while (i < data.length && data[i] != "}") {
            uint256 keyStart = i;
            bool ok;
            (i, ok) = _string(data, i);
            if (!ok) return (false, 0, "", false);
            uint256 keyEnd = i;
            i = _ws(data, i);
            if (i == data.length || data[i] != ":") return (false, 0, "", false);
            i = _ws(data, i + 1);
            uint256 valueStart = i;
            if (_same(data, keyStart, keyEnd, '"files"') && i < data.length && data[i] == "[") {
                (i, ok, image, hashValid, imageHash) = _files(data, i);
            } else {
                (i, ok) = _value(data, i, 0);
                if (_same(data, keyStart, keyEnd, '"complete"')) {
                    complete = _same(data, valueStart, i, "true");
                } else if (_same(data, keyStart, keyEnd, '"state"')) {
                    completed = _same(data, valueStart, i, '"completed"');
                } else if (_same(data, keyStart, keyEnd, '"jobId"')) {
                    jobStart = valueStart;
                    jobEnd = i;
                    jobSeen = true;
                }
            }
            if (!ok) return (false, 0, "", false);
            i = _ws(data, i);
            if (i < data.length && data[i] == ",") {
                i = _ws(data, i + 1);
                if (i == data.length || data[i] == "}") return (false, 0, "", false);
            } else if (i < data.length && data[i] != "}") {
                return (false, 0, "", false);
            }
        }
        if (i == data.length || _ws(data, i + 1) != data.length) return (false, 0, "", false);
        if (!image || !complete || !completed) return (false, 0, "", true);
        if (!hashValid || !jobSeen) return (false, 0, "", false);
        (jobId, valid) = _uuid(data, jobStart, jobEnd);
        if (!valid) return (false, 0, "", false);
        return (true, imageHash, jobId, false);
    }

    function _files(bytes calldata data, uint256 i)
        private
        pure
        returns (uint256, bool, bool image, bool hashValid, bytes32 imageHash)
    {
        i = _ws(data, i + 1);
        while (i < data.length && data[i] != "]") {
            bool ok;
            bool entryImage;
            bool entryHashValid;
            bytes32 entryHash;
            if (data[i] == "{") {
                (i, ok, entryImage, entryHashValid, entryHash) = _file(data, i);
            } else {
                (i, ok) = _value(data, i, 1);
            }
            if (!ok) return (i, false, false, false, 0);
            if (entryImage) {
                image = true;
                hashValid = entryHashValid;
                imageHash = entryHash;
            }
            i = _ws(data, i);
            if (i < data.length && data[i] == ",") {
                i = _ws(data, i + 1);
                if (i == data.length || data[i] == "]") return (i, false, false, false, 0);
            } else if (i < data.length && data[i] != "]") {
                return (i, false, false, false, 0);
            }
        }
        if (i == data.length) return (i, false, false, false, 0);
        return (i + 1, true, image, hashValid, imageHash);
    }

    function _file(bytes calldata data, uint256 i)
        private
        pure
        returns (uint256, bool, bool image, bool hashValid, bytes32 imageHash)
    {
        i = _ws(data, i + 1);
        bool named;
        bool media;
        uint256 hashStart;
        uint256 hashEnd;
        while (i < data.length && data[i] != "}") {
            uint256 keyStart = i;
            bool ok;
            (i, ok) = _string(data, i);
            if (!ok) return (i, false, false, false, 0);
            uint256 keyEnd = i;
            i = _ws(data, i);
            if (i == data.length || data[i] != ":") return (i, false, false, false, 0);
            i = _ws(data, i + 1);
            uint256 valueStart = i;
            (i, ok) = _value(data, i, 2);
            if (!ok) return (i, false, false, false, 0);
            if (_same(data, keyStart, keyEnd, '"name"')) {
                named = _same(data, valueStart, i, '"image"');
            } else if (_same(data, keyStart, keyEnd, '"mediaType"')) {
                media = i >= valueStart + 8 && _same(data, valueStart, valueStart + 7, '"image/');
            } else if (_same(data, keyStart, keyEnd, '"hash"')) {
                hashStart = valueStart;
                hashEnd = i;
            }
            i = _ws(data, i);
            if (i < data.length && data[i] == ",") {
                i = _ws(data, i + 1);
                if (i == data.length || data[i] == "}") return (i, false, false, false, 0);
            } else if (i < data.length && data[i] != "}") {
                return (i, false, false, false, 0);
            }
        }
        if (i == data.length) return (i, false, false, false, 0);
        image = named && media;
        if (image) (imageHash, hashValid) = _hash(data, hashStart, hashEnd);
        return (i + 1, true, image, hashValid, imageHash);
    }

    function _value(bytes calldata data, uint256 i, uint256 depth) private pure returns (uint256, bool) {
        if (i == data.length || depth > 32) return (i, false);
        bytes1 c = data[i];
        if (c == '"') return _string(data, i);
        if (c == "{" || c == "[") {
            bytes1 close = c == "{" ? bytes1("}") : bytes1("]");
            i = _ws(data, i + 1);
            while (i < data.length && data[i] != close) {
                bool ok;
                if (c == "{") {
                    (i, ok) = _string(data, i);
                    if (!ok) return (i, false);
                    i = _ws(data, i);
                    if (i == data.length || data[i] != ":") return (i, false);
                    i = _ws(data, i + 1);
                }
                (i, ok) = _value(data, i, depth + 1);
                if (!ok) return (i, false);
                i = _ws(data, i);
                if (i < data.length && data[i] == ",") {
                    i = _ws(data, i + 1);
                    if (i == data.length || data[i] == close) return (i, false);
                } else if (i < data.length && data[i] != close) {
                    return (i, false);
                }
            }
            if (i == data.length) return (i, false);
            return (i + 1, true);
        }
        if (c == "t") return _literal(data, i, "true");
        if (c == "f") return _literal(data, i, "false");
        if (c == "n") return _literal(data, i, "null");
        if (c == "-" || _digit(c)) return _number(data, i);
        return (i, false);
    }

    function _string(bytes calldata data, uint256 i) private pure returns (uint256, bool) {
        if (i == data.length || data[i] != '"') return (i, false);
        for (++i; i < data.length; ++i) {
            bytes1 c = data[i];
            if (c == '"') return (i + 1, true);
            if (uint8(c) < 32) return (i, false);
            if (c == "\\") {
                if (++i == data.length) return (i, false);
                c = data[i];
                if (c == "u") {
                    if (i + 4 >= data.length) return (i, false);
                    for (uint256 j = 1; j <= 4; ++j) {
                        if (!_hex(data[i + j])) return (i, false);
                    }
                    i += 4;
                } else if (
                    c != '"' && c != "\\" && c != "/" && c != "b" && c != "f" && c != "n" && c != "r" && c != "t"
                ) {
                    return (i, false);
                }
            }
        }
        return (i, false);
    }

    function _number(bytes calldata data, uint256 i) private pure returns (uint256, bool) {
        if (data[i] == "-") ++i;
        if (i == data.length || !_digit(data[i])) return (i, false);
        if (data[i] == "0") {
            ++i;
            if (i < data.length && _digit(data[i])) return (i, false);
        } else {
            while (i < data.length && _digit(data[i])) ++i;
        }
        if (i < data.length && data[i] == ".") {
            ++i;
            if (i == data.length || !_digit(data[i])) return (i, false);
            while (i < data.length && _digit(data[i])) ++i;
        }
        if (i < data.length && (data[i] == "e" || data[i] == "E")) {
            ++i;
            if (i < data.length && (data[i] == "+" || data[i] == "-")) ++i;
            if (i == data.length || !_digit(data[i])) return (i, false);
            while (i < data.length && _digit(data[i])) ++i;
        }
        return (i, true);
    }

    function _hash(bytes calldata data, uint256 start, uint256 end) private pure returns (bytes32 hash, bool ok) {
        if (end != start + 66 || data[start] != '"' || data[end - 1] != '"') return (0, false);
        for (uint256 i = start + 1; i < end - 1; ++i) {
            bytes1 c = data[i];
            if (!_hex(c)) return (0, false);
            uint8 n = uint8(c);
            n = n <= 57 ? n - 48 : n <= 70 ? n - 55 : n - 87;
            hash = bytes32((uint256(hash) << 4) | n);
        }
        return (hash, true);
    }

    function _uuid(bytes calldata data, uint256 start, uint256 end) private pure returns (string memory id, bool ok) {
        if (end != start + 38 || data[start] != '"' || data[end - 1] != '"') return ("", false);
        bytes memory out = new bytes(36);
        for (uint256 i; i < 36; ++i) {
            bytes1 c = data[start + i + 1];
            if (i == 8 || i == 13 || i == 18 || i == 23) {
                if (c != "-") return ("", false);
            } else if (!_hex(c)) {
                return ("", false);
            }
            out[i] = c;
        }
        return (string(out), true);
    }

    function _literal(bytes calldata data, uint256 i, bytes memory word) private pure returns (uint256, bool) {
        if (!_same(data, i, i + word.length, word)) return (i, false);
        return (i + word.length, true);
    }

    function _same(bytes calldata data, uint256 start, uint256 end, bytes memory expected) private pure returns (bool) {
        if (end > data.length || end - start != expected.length) return false;
        for (uint256 i; i < expected.length; ++i) {
            if (data[start + i] != expected[i]) return false;
        }
        return true;
    }

    function _ws(bytes calldata data, uint256 i) private pure returns (uint256) {
        while (i < data.length && (data[i] == " " || data[i] == "\n" || data[i] == "\r" || data[i] == "\t")) ++i;
        return i;
    }

    function _digit(bytes1 c) private pure returns (bool) {
        return c >= "0" && c <= "9";
    }

    function _hex(bytes1 c) private pure returns (bool) {
        return _digit(c) || (c >= "a" && c <= "f") || (c >= "A" && c <= "F");
    }
}
