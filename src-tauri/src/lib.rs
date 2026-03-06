// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  tauri::Builder::default()
    .plugin(tauri_plugin_shell::init())
    .setup(|app| {
        use tauri_plugin_shell::ShellExt;
        
        let sidecar_command = app.shell().sidecar("kora").unwrap();
        let (mut rx, _child) = sidecar_command.spawn().unwrap();

        tauri::async_runtime::spawn(async move {
            use tauri_plugin_shell::process::CommandEvent;
            while let Some(event) = rx.recv().await {
                if let CommandEvent::Stdout(line) = event {
                    print!("{}", String::from_utf8_lossy(&line));
                }
                if let CommandEvent::Stderr(line) = event {
                    eprint!("{}", String::from_utf8_lossy(&line));
                }
            }
        });
        Ok(())
    })
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
