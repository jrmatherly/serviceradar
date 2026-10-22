//! `Display` redacts, so interpolating a secret into a message cannot leak it.

use crate::types::secret::{REDACTED, Secret};
use std::fmt;

impl fmt::Display for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(REDACTED)
    }
}
