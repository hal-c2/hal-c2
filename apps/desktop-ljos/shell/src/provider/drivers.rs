//! The provider drivers a user can add an instance of, with the settings
//! each one's form shows, desktop-qt's `ProviderDrivers`: the driver options
//! and the `providerSettingsForm` annotations of packages/contracts
//! settings.ts, whose order and wording these follow. Keep them in step when
//! a driver's settings change there.

use std::collections::BTreeSet;

/// One setting of a driver's `config` blob.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Field {
    pub key: &'static str,
    pub label: &'static str,
    pub description: &'static str,
    pub placeholder: &'static str,
    /// text | password | select
    pub control: &'static str,
    /// A select's choices, `(value, label)`; the first is the default.
    pub options: &'static [(&'static str, &'static str)],
    /// An emptied field is kept as "" rather than removed.
    pub keep_empty: bool,
}

/// An environment variable the driver's form asks for by name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Variable {
    pub name: &'static str,
    pub label: &'static str,
    pub description: &'static str,
    pub placeholder: &'static str,
    pub sensitive: bool,
}

/// A custom model option the driver reads, and its usual choices
/// (descriptor presets by kind).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ModelOption {
    pub id: &'static str,
    pub label: &'static str,
    /// select | boolean
    pub kind: &'static str,
    /// `(id, label)`; `default_choice` names the default.
    pub choices: &'static [(&'static str, &'static str)],
    pub default_choice: &'static str,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Driver {
    pub id: &'static str,
    pub label: &'static str,
    /// "Early Access" and the like.
    pub badge: &'static str,
    /// Whether HAL-C2 lists an instance named after the driver without one
    /// being added.
    pub built_in: bool,
    pub fields: &'static [Field],
    pub variables: &'static [Variable],
    pub options: &'static [ModelOption],
}

type Choices = &'static [(&'static str, &'static str)];

const fn field(
    key: &'static str,
    label: &'static str,
    description: &'static str,
    placeholder: &'static str,
) -> Field {
    Field {
        key,
        label,
        description,
        placeholder,
        control: "text",
        options: &[],
        keep_empty: false,
    }
}

const fn binary_path(description: &'static str, placeholder: &'static str) -> Field {
    field("binaryPath", "Binary path", description, placeholder)
}

const fn password(
    key: &'static str,
    label: &'static str,
    description: &'static str,
    placeholder: &'static str,
) -> Field {
    Field {
        control: "password",
        ..field(key, label, description, placeholder)
    }
}

const EFFORT: Choices = &[
    ("low", "Low"),
    ("medium", "Medium"),
    ("high", "High"),
    ("xhigh", "Extra High"),
];

const EFFORT_MAX: Choices = &[
    ("low", "Low"),
    ("medium", "Medium"),
    ("high", "High"),
    ("xhigh", "Extra High"),
    ("max", "Max"),
];

const fn select(
    id: &'static str,
    label: &'static str,
    choices: Choices,
    default_choice: &'static str,
) -> ModelOption {
    ModelOption {
        id,
        label,
        kind: "select",
        choices,
        default_choice,
    }
}

const fn effort(id: &'static str) -> ModelOption {
    select(id, "Reasoning", EFFORT, "medium")
}

const fn flag(id: &'static str, label: &'static str) -> ModelOption {
    ModelOption {
        id,
        label,
        kind: "boolean",
        choices: &[],
        default_choice: "",
    }
}

const fn driver(
    id: &'static str,
    label: &'static str,
    badge: &'static str,
    built_in: bool,
    fields: &'static [Field],
    variables: &'static [Variable],
    options: &'static [ModelOption],
) -> Driver {
    Driver {
        id,
        label,
        badge,
        built_in,
        fields,
        variables,
        options,
    }
}

static DRIVERS: [Driver; 9] = [
    driver(
        "codex",
        "Codex",
        "",
        true,
        &[
            binary_path("Path to the Codex binary used by this instance.", "codex"),
            field(
                "homePath",
                "CODEX_HOME path",
                "Custom Codex home and config directory.",
                "~/.codex",
            ),
            field(
                "shadowHomePath",
                "Shadow home path",
                "Account-specific Codex home. Keeps auth.json separate while sharing state from CODEX_HOME.",
                "~/.codex-hal-c2/personal",
            ),
            field(
                "launchArgs",
                "Launch arguments",
                "Additional CLI arguments passed to codex app-server on session start.",
                "",
            ),
        ],
        &[],
        &[
            effort("reasoningEffort"),
            select(
                "serviceTier",
                "Speed",
                &[("default", "Standard"), ("fast", "Fast")],
                "default",
            ),
        ],
    ),
    driver(
        "claudeAgent",
        "Claude",
        "",
        true,
        &[
            binary_path("Path to the Claude binary used by this instance.", "claude"),
            field(
                "homePath",
                "CLAUDE_CONFIG_DIR path",
                "Custom Claude home and config directory. Keeps .claude.json and .claude separate.",
                "~/.claude",
            ),
            field(
                "autoCompactWindow",
                "Auto-compact after",
                "Compact after 100,000 to 1,000,000 tokens. Leave empty to use Claude's default.",
                "e.g. 300000",
            ),
            field(
                "launchArgs",
                "Launch arguments",
                "Additional CLI arguments passed on session start.",
                "e.g. --chrome",
            ),
        ],
        &[],
        &[
            select("effort", "Reasoning", EFFORT_MAX, "high"),
            flag("fastMode", "Fast Mode"),
            flag("thinking", "Thinking"),
        ],
    ),
    driver(
        "cursor",
        "Cursor",
        "",
        true,
        &[],
        &[Variable {
            name: "CURSOR_API_KEY",
            label: "Cursor API key",
            description: "Optional. Overrides browser sign-in for this provider.",
            placeholder: "Paste API key",
            sensitive: true,
        }],
        &[
            effort("reasoning"),
            flag("fastMode", "Fast Mode"),
            flag("thinking", "Thinking"),
        ],
    ),
    driver(
        "grok",
        "Grok",
        "",
        true,
        &[binary_path("Path to the Grok CLI binary.", "grok")],
        &[],
        &[effort("reasoningEffort")],
    ),
    driver(
        "opencode",
        "OpenCode",
        "",
        true,
        &[
            binary_path("Path to the OpenCode binary.", "opencode"),
            field(
                "serverUrl",
                "Server URL",
                "Leave blank to let HAL-C2 spawn the server when needed.",
                "http://127.0.0.1:4096",
            ),
            password(
                "serverPassword",
                "Server password",
                "Stored in plain text on disk.",
                "Optional",
            ),
        ],
        &[],
        &[
            effort("variant"),
            select(
                "agent",
                "Agent",
                &[("build", "Build"), ("plan", "Plan")],
                "build",
            ),
        ],
    ),
    driver(
        "antigravity",
        "Antigravity",
        "",
        true,
        &[
            Field {
                control: "select",
                options: &[
                    ("oauth-personal", "Google account"),
                    ("oauth-business", "Gemini Enterprise"),
                    ("gemini-api-key", "Gemini API key"),
                    ("agent-platform", "Agent Platform (Vertex AI)"),
                ],
                ..field(
                    "authMethod",
                    "Sign-in method",
                    "Google accounts use your subscription; API keys and Agent Platform bill usage.",
                    "",
                )
            },
            password(
                "apiKey",
                "API key",
                "Gemini or Vertex AI express key. Stored in plain text.",
                "Optional",
            ),
            field(
                "gcpProject",
                "GCP project",
                "Required for Gemini Enterprise. Agent Platform uses it when no API key is set.",
                "my-project-id",
            ),
            field(
                "gcpLocation",
                "GCP location",
                "Region for Gemini Enterprise or Agent Platform.",
                "us-central1",
            ),
            Field {
                keep_empty: true,
                ..binary_path(
                    "Custom ACP executable. Leave empty to select automatically.",
                    "Automatic",
                )
            },
        ],
        &[],
        &[],
    ),
    driver(
        "pi",
        "Pi",
        "Early Access",
        true,
        &[
            binary_path("Path to the Pi coding agent binary.", "pi"),
            field(
                "launchArgs",
                "Launch arguments",
                "Additional CLI arguments passed to pi --mode rpc on session start.",
                "",
            ),
        ],
        &[],
        &[select(
            "thinking",
            "Thinking",
            &[
                ("off", "Off"),
                ("minimal", "Minimal"),
                ("low", "Low"),
                ("medium", "Medium"),
                ("high", "High"),
                ("xhigh", "Extra High"),
                ("max", "Max"),
            ],
            "medium",
        )],
    ),
    driver(
        "muse",
        "Muse Code",
        "Beta",
        true,
        &[binary_path(
            "Path to the Muse Code binary on this environment. Sign in with `muse login` on that host.",
            "muse",
        )],
        &[],
        &[select("reasoningEffort", "Reasoning", EFFORT_MAX, "high")],
    ),
    driver(
        "acpRegistry",
        "ACP Registry",
        "Early Access",
        false,
        &[
            Field {
                keep_empty: true,
                ..field(
                    "agentId",
                    "Registry agent ID",
                    "Agent identifier from the official ACP Registry, for example 'devin'.",
                    "devin",
                )
            },
            field(
                "commandPath",
                "Executable override",
                "Optional local executable to use instead of installing the registry distribution. Registry arguments and environment are still applied.",
                "Registry default",
            ),
            field(
                "authMethodId",
                "Authentication method",
                "Optional ACP authentication method ID. By default, the first agent-managed method is selected.",
                "auto",
            ),
        ],
        &[],
        &[],
    ),
];

/// Every driver, in the order the wizard lists them.
pub fn all() -> &'static [Driver] {
    &DRIVERS
}

pub fn find(id: &str) -> Option<&'static Driver> {
    DRIVERS.iter().find(|d| d.id == id)
}

/// A label as an instance id suffix: lower case, runs of other characters as
/// one "_", at most 48 characters.
pub fn slug(label: &str) -> String {
    let mut out = String::new();
    for c in label.trim().chars().flat_map(char::to_lowercase) {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            out.push(c);
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    out.trim_matches('_').chars().take(48).collect()
}

/// The id for a new instance labelled `label`: the driver alone for its own
/// label or none, else "<driver>_<slug>", numbered "_2", "_3", … past the
/// taken ones; the ACP Registry has no instance of its own, so
/// "acpRegistry_custom". Empty when the label has nothing to name it by.
pub fn derive_id(driver: &str, label: &str, taken: &BTreeSet<String>) -> String {
    let found = find(driver);
    let base = if label.trim().is_empty() || found.is_some_and(|d| d.label == label) {
        if found.is_some_and(|d| !d.built_in) {
            format!("{driver}_custom")
        } else {
            driver.to_owned()
        }
    } else {
        match slug(label).as_str() {
            "" => String::new(),
            suffix => format!("{driver}_{suffix}"),
        }
    };
    if base.is_empty() || !taken.contains(&base) {
        return base;
    }
    (2..)
        .map(|number| {
            let suffix = format!("_{number}");
            let head: String = base.chars().take(64 - suffix.len()).collect();
            head + &suffix
        })
        .find(|candidate| !taken.contains(candidate))
        .unwrap_or_default()
}

/// Why `id` cannot name a new instance, or empty.
pub fn validate_id(id: &str, taken: &BTreeSet<String>) -> String {
    if id.is_empty() {
        return "Instance ID is required.".into();
    }
    if id.encode_utf16().count() > 64 {
        return "Instance ID must be 64 characters or fewer.".into();
    }
    let mut chars = id.chars();
    let valid = chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    if !valid {
        return "Instance ID must start with a letter and use only letters, digits, '-', or '_'."
            .into();
    }
    if taken.contains(id) {
        return format!("An instance named '{id}' already exists.");
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn taken(ids: &[&str]) -> BTreeSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn every_driver_is_listed_once_with_its_form() {
        let ids: Vec<_> = all().iter().map(|d| d.id).collect();
        assert_eq!(
            ids,
            [
                "codex",
                "claudeAgent",
                "cursor",
                "grok",
                "opencode",
                "antigravity",
                "pi",
                "muse",
                "acpRegistry"
            ]
        );
        assert_eq!(find("codex").unwrap().fields[0].key, "binaryPath");
        assert_eq!(find("cursor").unwrap().variables[0].name, "CURSOR_API_KEY");
        assert!(find("cursor").unwrap().variables[0].sensitive);
        assert!(find("nobody").is_none());
        assert_eq!(
            all()
                .iter()
                .filter(|d| !d.built_in)
                .map(|d| d.id)
                .collect::<Vec<_>>(),
            ["acpRegistry"]
        );
        // A select names its choices and a select option its default.
        for driver in all() {
            for field in driver.fields {
                assert_eq!(
                    field.control == "select",
                    !field.options.is_empty(),
                    "{}",
                    field.key
                );
            }
            for option in driver.options.iter().filter(|o| o.kind == "select") {
                assert!(
                    option
                        .choices
                        .iter()
                        .any(|(id, _)| *id == option.default_choice),
                    "{}: {}",
                    driver.id,
                    option.id
                );
            }
        }
    }

    #[test]
    fn a_label_becomes_a_slug() {
        assert_eq!(slug("  Work Account! "), "work_account");
        assert_eq!(slug("--a--b--"), "a_b");
        assert_eq!(slug("日本"), "");
        assert_eq!(slug(&"x".repeat(60)).len(), 48);
    }

    #[test]
    fn the_drivers_own_label_or_none_takes_the_driver_id() {
        assert_eq!(derive_id("codex", "", &taken(&[])), "codex");
        assert_eq!(derive_id("codex", "  ", &taken(&[])), "codex");
        assert_eq!(derive_id("codex", "Codex", &taken(&[])), "codex");
        assert_eq!(
            derive_id("acpRegistry", "", &taken(&[])),
            "acpRegistry_custom"
        );
    }

    #[test]
    fn another_label_is_a_suffix_numbered_past_the_taken_ones() {
        assert_eq!(derive_id("codex", "Work", &taken(&[])), "codex_work");
        assert_eq!(
            derive_id("codex", "Work", &taken(&["codex_work"])),
            "codex_work_2"
        );
        assert_eq!(
            derive_id("codex", "Work", &taken(&["codex_work", "codex_work_2"])),
            "codex_work_3"
        );
        assert_eq!(derive_id("codex", "日本", &taken(&[])), "");
        assert_eq!(derive_id("codex", "", &taken(&["codex"])), "codex_2");
    }

    #[test]
    fn a_numbered_id_stays_within_64_characters() {
        let long = format!("codex_{}", "x".repeat(48));
        let id = derive_id("codex", &"x".repeat(60), &taken(&[&long]));
        assert!(id.len() <= 64 && id.ends_with("_2"), "{id}");
    }

    #[test]
    fn an_id_is_checked_before_it_is_used() {
        let taken = taken(&["codex"]);
        assert_eq!(validate_id("codex_work", &taken), "");
        assert_eq!(validate_id("", &taken), "Instance ID is required.");
        assert_eq!(
            validate_id(&"a".repeat(65), &taken),
            "Instance ID must be 64 characters or fewer."
        );
        assert!(validate_id(&"a".repeat(64), &taken).is_empty());
        for bad in ["1a", "-a", "a b", "a.b"] {
            assert!(
                validate_id(bad, &taken).starts_with("Instance ID must start"),
                "{bad}"
            );
        }
        assert_eq!(
            validate_id("codex", &taken),
            "An instance named 'codex' already exists."
        );
    }
}
