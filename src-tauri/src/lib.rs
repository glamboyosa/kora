// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use tauri::Manager;
use std::sync::{Arc, Mutex};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  tauri::Builder::default()
    .plugin(tauri_plugin_shell::init())
    .setup(|app| {
        use tauri_plugin_shell::ShellExt;
        
        let sidecar_command = app.shell().sidecar("kora").unwrap();
        let (mut rx, _child) = sidecar_command.spawn().unwrap();
        let app_handle = app.handle().clone();

        tauri::async_runtime::spawn(async move {
            use tauri_plugin_shell::process::CommandEvent;
            while let Some(event) = rx.recv().await {
                match event {
                    CommandEvent::Stdout(line) => {
                        let text = String::from_utf8_lossy(&line);
                        print!("{}", text); // Print to parent stdout for debug
                        
                        if text.contains("KORA_PORT=") {
                            if let Some(port_str) = text.trim().split('=').nth(1) {
                                if let Ok(port) = port_str.parse::<u16>() {
                                    println!("Detected Kora on port: {}", port);
                                    let url = format!("http://localhost:{}", port);
                                    
                                    // Navigate the main window
                                    if let Some(window) = app_handle.get_webview_window("main") {
                                        let _ = window.eval(&format!("window.location.replace('{}')", url));
                                    }
                                }
                            }
                        }
                    }
                    CommandEvent::Stderr(line) => {
                        eprint!("{}", String::from_utf8_lossy(&line));
                    }
                    _ => {}
                }
            }
        });
        Ok(())
    })
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
