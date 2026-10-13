//! Bencode helpers we need beyond what `serde_bencode` gives us.
//!
//! `ut_metadata` data messages contain a bencoded dict followed by raw bytes,
//! so we need to find where the dict ends ourselves.

/// Maximum list/dict nesting accepted from peers.
pub const MAX_DEPTH: usize = 64;

/// Length of the bencoded value starting at `buf[0]`, or `None` if `buf`
/// doesn't begin with a complete bencoded value nested at most [MAX_DEPTH] deep.
pub fn value_end(buf: &[u8]) -> Option<usize> {
    let mut i = 0;
    skip_value(buf, &mut i, 0).then_some(i)
}

fn skip_value(buf: &[u8], i: &mut usize, depth: usize) -> bool {
    let Some(&first) = buf.get(*i) else {
        return false;
    };
    match first {
        b'd' | b'l' => {
            if depth >= MAX_DEPTH {
                return false;
            }
            *i += 1;
            while buf.get(*i) != Some(&b'e') {
                if !skip_value(buf, i, depth + 1) {
                    return false;
                }
            }
            *i += 1;
            true
        }
        b'i' => {
            *i += 1;
            while buf.get(*i).is_some_and(|c| *c != b'e') {
                *i += 1;
            }
            if buf.get(*i) != Some(&b'e') {
                return false;
            }
            *i += 1;
            true
        }
        c if c.is_ascii_digit() => {
            let mut len = 0usize;
            while let Some(&d) = buf.get(*i) {
                if !d.is_ascii_digit() {
                    break;
                }
                let Some(next) = len
                    .checked_mul(10)
                    .and_then(|l| l.checked_add((d - b'0') as usize))
                else {
                    return false;
                };
                len = next;
                *i += 1;
            }
            if buf.get(*i) != Some(&b':') {
                return false;
            }
            *i += 1;
            if len > buf.len() - *i {
                return false;
            }
            *i += len;
            true
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ends_at_simple_dict() {
        assert_eq!(value_end(b"d3:foo5:helloe"), Some(14));
    }

    #[test]
    fn ends_with_trailing_bytes() {
        assert_eq!(value_end(b"d3:foo5:helloeXXXX"), Some(14));
    }

    #[test]
    fn handles_int() {
        assert_eq!(value_end(b"i42e"), Some(4));
        assert_eq!(value_end(b"i-7e"), Some(4));
    }

    #[test]
    fn handles_string() {
        assert_eq!(value_end(b"5:hello"), Some(7));
        assert_eq!(value_end(b"0:"), Some(2));
    }

    #[test]
    fn handles_list() {
        assert_eq!(value_end(b"li1ei2ei3ee"), Some(11));
    }

    #[test]
    fn handles_nested() {
        assert_eq!(value_end(b"d1:al1:xee"), Some(10)); // {a: ["x"]}
    }

    #[test]
    fn rejects_truncated() {
        assert_eq!(value_end(b"d3:foo"), None);
        assert_eq!(value_end(b"i42"), None);
        assert_eq!(value_end(b"5:hel"), None);
    }

    #[test]
    fn rejects_overflowing_length() {
        assert_eq!(value_end(b"d18446744073709551595:"), None);
        assert_eq!(value_end(b"99999999999999999999999:x"), None);
    }

    #[test]
    fn limits_nesting_depth() {
        let ok = [vec![b'l'; MAX_DEPTH], vec![b'e'; MAX_DEPTH]].concat();
        assert_eq!(value_end(&ok), Some(ok.len()));
        let deep = [vec![b'l'; MAX_DEPTH + 1], vec![b'e'; MAX_DEPTH + 1]].concat();
        assert_eq!(value_end(&deep), None);
        assert_eq!(value_end(&vec![b'l'; 1_000_000]), None);
    }
}
