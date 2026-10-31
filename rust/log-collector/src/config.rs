use log::warn;
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default)]
    pub flowgger: FlowggerInput,

    #[serde(default)]
    pub otel: OtelInput,

    #[serde(default)]
    pub health: HealthConfig,
}

impl Config {
    /// The package ships neither native config; each collector bundle adds its
    /// own. An input with no file on this host is one that was not installed.
    pub fn without_unconfigured_inputs(mut self) -> Self {
        for (name, enabled, file) in [
            (
                "flowgger",
                &mut self.flowgger.enabled,
                &self.flowgger.config_file,
            ),
            ("otel", &mut self.otel.enabled, &self.otel.config_file),
        ] {
            if *enabled && !Path::new(file).exists() {
                warn!("Skipping {name} input: {file} does not exist");
                *enabled = false;
            }
        }
        self
    }
}

/// Configuration for the unified gRPC health check server.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthConfig {
    /// gRPC health server listen address (default "0.0.0.0:50044").
    #[serde(default = "default_health_listen")]
    pub listen_addr: String,
}

impl Default for HealthConfig {
    fn default() -> Self {
        Self {
            listen_addr: default_health_listen(),
        }
    }
}

fn default_health_listen() -> String {
    "0.0.0.0:50044".to_string()
}

/// Configuration for the Flowgger syslog/GELF pipeline.
/// When enabled, Flowgger is started with the referenced TOML config file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlowggerInput {
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Path to the Flowgger TOML config file (its native format).
    #[serde(default = "default_flowgger_config")]
    pub config_file: String,
}

impl Default for FlowggerInput {
    fn default() -> Self {
        Self {
            enabled: true,
            config_file: default_flowgger_config(),
        }
    }
}

/// Configuration for the OTEL gRPC collector.
/// When enabled, the OTEL collector is started with the referenced TOML config file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OtelInput {
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Path to the OTEL TOML config file (its native format).
    #[serde(default = "default_otel_config")]
    pub config_file: String,
}

impl Default for OtelInput {
    fn default() -> Self {
        Self {
            enabled: true,
            config_file: default_otel_config(),
        }
    }
}

fn default_true() -> bool {
    true
}

fn default_flowgger_config() -> String {
    "/etc/serviceradar/flowgger.toml".to_string()
}

fn default_otel_config() -> String {
    "/etc/serviceradar/otel.toml".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_with(flowgger: &str, otel: &str) -> Config {
        Config {
            flowgger: FlowggerInput {
                enabled: true,
                config_file: flowgger.to_string(),
            },
            otel: OtelInput {
                enabled: true,
                config_file: otel.to_string(),
            },
            health: HealthConfig::default(),
        }
    }

    #[test]
    fn an_input_without_its_config_file_is_skipped() {
        let present =
            std::env::temp_dir().join(format!("log-collector-input-{}.toml", std::process::id()));
        std::fs::write(&present, "").unwrap();
        let present = present.to_str().unwrap().to_string();
        let absent = format!("{present}.absent");

        let flowgger_only = config_with(&present, &absent).without_unconfigured_inputs();
        assert!(flowgger_only.flowgger.enabled);
        assert!(!flowgger_only.otel.enabled);

        let otel_only = config_with(&absent, &present).without_unconfigured_inputs();
        assert!(!otel_only.flowgger.enabled);
        assert!(otel_only.otel.enabled);

        let both = config_with(&present, &present).without_unconfigured_inputs();
        assert!(both.flowgger.enabled && both.otel.enabled);

        std::fs::remove_file(&present).unwrap();
    }

    #[test]
    fn a_disabled_input_stays_disabled_when_its_config_exists() {
        let present = std::env::temp_dir().join(format!(
            "log-collector-disabled-{}.toml",
            std::process::id()
        ));
        std::fs::write(&present, "").unwrap();
        let present = present.to_str().unwrap().to_string();

        let mut config = config_with(&present, &present);
        config.otel.enabled = false;
        assert!(!config.without_unconfigured_inputs().otel.enabled);

        std::fs::remove_file(&present).unwrap();
    }

    #[test]
    fn test_defaults() {
        let config: Config = toml::from_str("").unwrap();
        assert!(config.flowgger.enabled);
        assert!(config.otel.enabled);
        assert_eq!(
            config.flowgger.config_file,
            "/etc/serviceradar/flowgger.toml"
        );
        assert_eq!(config.otel.config_file, "/etc/serviceradar/otel.toml");
        assert_eq!(config.health.listen_addr, "0.0.0.0:50044");
    }

    #[test]
    fn test_disable_otel() {
        let config: Config = toml::from_str(
            r#"
            [otel]
            enabled = false
            "#,
        )
        .unwrap();
        assert!(config.flowgger.enabled);
        assert!(!config.otel.enabled);
    }

    #[test]
    fn test_custom_paths() {
        let config: Config = toml::from_str(
            r#"
            [flowgger]
            config_file = "/custom/flowgger.toml"

            [otel]
            config_file = "/custom/otel.toml"
            "#,
        )
        .unwrap();
        assert_eq!(config.flowgger.config_file, "/custom/flowgger.toml");
        assert_eq!(config.otel.config_file, "/custom/otel.toml");
    }
}
