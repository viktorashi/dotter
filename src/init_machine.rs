use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use inquire::Select;

use crate::args::Options;
use crate::config::{LocalConfig, MachineConfig};
use crate::deploy;
use crate::filesystem;

pub fn setup_machine(opt: &Options, explicit: bool) -> Result<bool> {
    let local_exists = opt.local_config.exists();
    
    // Check if it's already set up via hostname fallback
    let mut hostname_config = opt.local_config.to_path_buf();
    if let Ok(hostname) = hostname::get() {
        if let Ok(hostname_str) = hostname.into_string() {
            hostname_config.set_file_name(format!("{hostname_str}.toml"));
        }
    }
    let hostname_exists = hostname_config.exists();
    
    let is_set_up = local_exists || hostname_exists;

    if is_set_up {
        if !explicit {
            return Ok(false);
        }
        
        println!("Machine is already set up. Undeploying current machine before switching...");
        // Ensure we undeploy the currently set up machine
        deploy::undeploy(opt).context("undeploy current machine")?;
        
        if local_exists {
            fs::remove_file(&opt.local_config).context("remove local.toml")?;
        }
        // We don't remove hostname.toml because they might just be switching to it.
        // Actually, if local_exists was false, they were using hostname.toml. 
        // Let's just create local.toml for the new machine which overrides hostname.toml.
    } else {
        if explicit {
            println!("No machine configured yet. Let's set one up.");
        }
    }

    // 1. Probe OS and distro
    let probe = get_os_probe();

    // 2. List .dotter/machines/*.toml
    let machines_dir = opt.local_config.parent().unwrap_or(Path::new("")).join("machines");
    let mut machines = Vec::new();
    if machines_dir.exists() {
        for entry in fs::read_dir(&machines_dir).context("read machines directory")? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().unwrap_or_default() == "toml" {
                if let Some(name) = path.file_stem().and_then(|s| s.to_str()) {
                    machines.push(name.to_string());
                }
            }
        }
    }

    // 3. Rank by similarity to probe (simple prefix/contains check for now)
    // In a real implementation, we could read the files and check comments or tags.
    // For now, we'll just sort alphabetically, but prioritize if the machine name matches hostname or OS.
    machines.sort_by(|a, b| {
        let a_score = score_machine(a, &probe);
        let b_score = score_machine(b, &probe);
        b_score.cmp(&a_score).then_with(|| a.cmp(b))
    });

    const CREATE_NEW: &str = "(create a new machine)";
    let mut options = machines.clone();
    options.push(CREATE_NEW.to_string());

    let selection = Select::new("Which machine is this? (type to filter)", options)
        .with_vim_mode(true)
        .prompt()
        .context("prompt for machine selection")?;

    let selected_machine = if selection == CREATE_NEW {
        let new_name = inquire::Text::new("Enter new machine name:")
            .prompt()
            .context("prompt for new machine name")?;
        
        let new_machine_path = machines_dir.join(format!("{}.toml", new_name));
        
        let mut seed_options = machines.clone();
        seed_options.push("(empty)".to_string());
        
        let seed = Select::new("Seed from existing machine?", seed_options)
            .with_vim_mode(true)
            .prompt()
            .context("prompt for seed")?;
            
        fs::create_dir_all(&machines_dir).context("create machines dir")?;
        
        if seed != "(empty)" {
            let seed_path = machines_dir.join(format!("{}.toml", seed));
            fs::copy(&seed_path, &new_machine_path).context("copy seed machine")?;
            println!("Seeded {} from {}", new_name, seed);
        } else {
            let empty_machine = MachineConfig {
                packages: Vec::new(),
                ..Default::default()
            };
            filesystem::save_file(&new_machine_path, empty_machine).context("write empty machine")?;
            println!("Created empty machine {}", new_name);
        }
        
        new_name
    } else {
        selection
    };

    // 6. Write machine name to local.toml
    let new_local = LocalConfig {
        machine: Some(selected_machine.clone()),
        ..Default::default()
    };
    filesystem::save_file(&opt.local_config, new_local).context("write local.toml")?;
    
    println!("Successfully set up machine '{}'.", selected_machine);

    if explicit {
        println!("Deploying new machine...");
        deploy::deploy(opt).context("deploy new machine")?;
    }

    Ok(true)
}

fn get_os_probe() -> String {
    let mut probe = String::new();
    if let Ok(hostname) = hostname::get() {
        if let Ok(hostname_str) = hostname.into_string() {
            probe.push_str(&hostname_str);
        }
    }
    
    #[cfg(target_os = "linux")]
    {
        if let Ok(os_release) = fs::read_to_string("/etc/os-release") {
            for line in os_release.lines() {
                if let Some(id) = line.strip_prefix("ID=") {
                    probe.push(' ');
                    probe.push_str(id.trim_matches('"'));
                }
            }
        }
    }
    #[cfg(target_os = "macos")]
    {
        probe.push_str(" macos mac");
    }
    #[cfg(target_os = "windows")]
    {
        probe.push_str(" windows win");
    }
    
    probe.to_lowercase()
}

fn score_machine(name: &str, probe: &str) -> usize {
    let name_lower = name.to_lowercase();
    let mut score = 0;
    if probe.contains(&name_lower) {
        score += 10;
    }
    // basic token matching
    for token in probe.split_whitespace() {
        if name_lower.contains(token) {
            score += 5;
        }
    }
    score
}
