// This implementation is heavily inspired by std.base64.
const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const mem = std.mem;

pub const Error = error{
    InvalidCharacter,
    InvalidPadding,
    NoSpaceLeft,
};

/// Base32 32 32 codecs
pub const Codecs = struct {
    alphabet_chars: [32]u8,
    pad_char: ?u8,
    Encoder: Base32Encoder,
    Decoder: Base32Decoder,
};

pub const standard_alphabet_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".*;

/// Standard Base32 codecs, with padding
pub const standard = Codecs{
    .alphabet_chars = standard_alphabet_chars,
    .pad_char = '=',
    .Encoder = Base32Encoder.init(standard_alphabet_chars, '='),
    .Decoder = Base32Decoder.init(standard_alphabet_chars, '='),
};

/// Standard Base32 codecs, without padding
pub const standard_no_pad = Codecs{
    .alphabet_chars = standard_alphabet_chars,
    .pad_char = null,
    .Encoder = Base32Encoder.init(standard_alphabet_chars, null),
    .Decoder = Base32Decoder.init(standard_alphabet_chars, null),
};

pub const Base32Encoder = struct {
    alphabet_chars: [32]u8,
    pad_char: ?u8,

    /// A bunch of assertions, then simply pass the data right through.
    pub fn init(alphabet_chars: [32]u8, pad_char: ?u8) Base32Encoder {
        assert(alphabet_chars.len == 32);
        var char_in_alphabet = [_]bool{false} ** 256;
        for (alphabet_chars) |c| {
            assert(!char_in_alphabet[c]);
            assert(pad_char == null or c != pad_char.?);
            char_in_alphabet[c] = true;
        }
        return Base32Encoder{
            .alphabet_chars = alphabet_chars,
            .pad_char = pad_char,
        };
    }

    /// Compute the encoded length
    pub fn calcSize(encoder: *const Base32Encoder, source_len: usize) usize {
        if (encoder.pad_char != null) {
            return @divTrunc(source_len + 4, 5) * 8;
        } else {
            return @divTrunc(source_len * 8 + 4, 5);
        }
    }

    /// dest.len must at least be what you get from ::calcSize.
    pub fn encode(encoder: *const Base32Encoder, dest: []u8, source: []const u8) []const u8 {
        const out_len = encoder.calcSize(source.len);
        assert(dest.len >= out_len);

        var acc: u12 = 0;
        var acc_len: u4 = 0;
        var out_idx: usize = 0;
        for (source) |v| {
            acc = (acc << 8) + v;
            acc_len += 8;
            while (acc_len >= 5) {
                acc_len -= 5;
                dest[out_idx] = encoder.alphabet_chars[@as(u5, @truncate((acc >> acc_len)))];
                out_idx += 1;
            }
        }
        if (acc_len > 0) {
            dest[out_idx] = encoder.alphabet_chars[@as(u5, @truncate((acc << 5 - acc_len)))];
            out_idx += 1;
        }
        if (encoder.pad_char) |pad_char| {
            for (dest[out_idx..out_len]) |*pad| {
                pad.* = pad_char;
            }
        }
        return dest[0..out_len];
    }
};

pub const Base32Decoder = struct {
    const invalid_char: u8 = 0xff;

    /// e.g. 'A' => 0.
    /// `invalid_char` for any value not in the 32 alphabet chars.
    char_to_index: [256]u8,
    pad_char: ?u8,

    pub fn init(alphabet_chars: [32]u8, pad_char: ?u8) Base32Decoder {
        var result = Base32Decoder{
            .char_to_index = [_]u8{invalid_char} ** 256,
            .pad_char = pad_char,
        };

        var char_in_alphabet = [_]bool{false} ** 256;
        for (alphabet_chars, 0..) |c, i| {
            assert(!char_in_alphabet[c]);
            assert(pad_char == null or c != pad_char.?);

            result.char_to_index[c] = @as(u8, @intCast(i));
            char_in_alphabet[c] = true;
        }
        return result;
    }

    /// Return the maximum possible decoded size for a given input length - The actual length may be less if the input includes padding.
    /// `InvalidPadding` is returned if the input length is not valid.
    pub fn calcSizeUpperBound(decoder: *const Base32Decoder, source_len: usize) Error!usize {
        var result = source_len / 8 * 5;
        const leftover = source_len % 8;
        if (decoder.pad_char != null) {
            if (leftover != 0) return error.InvalidPadding;
        } else {
            result += switch (leftover) {
                0 => 0,
                2 => 1,
                4 => 2,
                5 => 3,
                7 => 4,
                else => return error.InvalidPadding,
            };
        }
        return result;
    }

    /// Return the exact decoded size for a slice.
    /// `InvalidPadding` is returned if the input length is not valid.
    pub fn calcSizeForSlice(decoder: *const Base32Decoder, source: []const u8) Error!usize {
        const source_len = source.len;
        var result = try decoder.calcSizeUpperBound(source_len);
        if (decoder.pad_char) |pad_char| {
            var i: usize = source.len;
            var k: usize = 0;
            while (i > 0) {
                i -= 1;
                if (source[i] != pad_char) {
                    break;
                }
                k += 1;
            }
            result -= switch (k) {
                0 => 0,
                6 => 4,
                4 => 3,
                3 => 2,
                1 => 1,
                else => return error.InvalidPadding,
            };
        }
        return result;
    }

    /// dest.len must be what you get from ::calcSize.
    /// invalid characters result in error.InvalidCharacter.
    /// invalid padding results in error.InvalidPadding.
    pub fn decode(decoder: *const Base32Decoder, dest: []u8, source: []const u8) Error!void {
        if (decoder.pad_char != null and source.len % 8 != 0) return error.InvalidPadding;
        var acc: u12 = 0;
        var acc_len: u4 = 0;
        var dest_idx: usize = 0;
        var leftover_idx: ?usize = null;
        for (source, 0..) |c, src_idx| {
            const d = decoder.char_to_index[c];
            if (d == invalid_char) {
                if (decoder.pad_char == null or c != decoder.pad_char.?) return error.InvalidCharacter;
                leftover_idx = src_idx;
                break;
            }
            acc = (acc << 5) + d;
            acc_len += 5;
            if (acc_len >= 8) {
                acc_len -= 8;
                dest[dest_idx] = @as(u8, @truncate(acc >> acc_len));
                dest_idx += 1;
            }
        }
        if (acc_len > 4 or (acc & (@as(u12, 1) << acc_len) - 1) != 0) {
            return error.InvalidPadding;
        }
        if (leftover_idx == null) return;
        const leftover = source[leftover_idx.?..];
        if (decoder.pad_char) |pad_char| {
            const padding_len: u4 = switch (acc_len) {
                2 => 6,
                4 => 4,
                1 => 3,
                3 => 1,
                else => return error.InvalidPadding,
            };
            var padding_chars: usize = 0;
            for (leftover) |c| {
                if (c != pad_char) {
                    return if (c == Base32Decoder.invalid_char) error.InvalidCharacter else error.InvalidPadding;
                }
                padding_chars += 1;
            }
            if (padding_chars != padding_len) return error.InvalidPadding;
        }
    }
};

test "no padding" {
    const test_cases = [_]struct {
        bytes: []const u8,
        expected: []const u8,
    }{
        .{ .bytes = "H", .expected = "JA" },
        .{ .bytes = "He", .expected = "JBSQ" },
        .{ .bytes = "Hel", .expected = "JBSWY" },
        .{ .bytes = "Hell", .expected = "JBSWY3A" },
        .{ .bytes = "Hello", .expected = "JBSWY3DP" },
        .{ .bytes = "Hello ", .expected = "JBSWY3DPEA" },
        .{ .bytes = "Hello s", .expected = "JBSWY3DPEBZQ" },
        .{ .bytes = "Hello si", .expected = "JBSWY3DPEBZWS" },
        .{ .bytes = "Hello sir", .expected = "JBSWY3DPEBZWS4Q" },
        .{ .bytes = "Hello sir!", .expected = "JBSWY3DPEBZWS4RB" },
    };

    inline for (test_cases) |tc| {
        // Encoding.
        {
            const size = standard_no_pad.Encoder.calcSize(tc.bytes.len);
            const buf = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(buf);
            const a = standard_no_pad.Encoder.encode(buf, tc.bytes);
            try std.testing.expectEqual(size, a.len);
            try std.testing.expectEqualSlices(u8, tc.expected, a);
        }

        // Decoding
        {
            const size = try standard_no_pad.Decoder.calcSizeForSlice(tc.expected);
            const buf = try std.testing.allocator.alloc(u8, size);
            defer std.testing.allocator.free(buf);
            try standard_no_pad.Decoder.decode(buf, tc.expected);
            try std.testing.expectEqualSlices(u8, tc.bytes, buf);
        }
    }
}
