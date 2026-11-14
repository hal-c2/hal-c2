//! The executable CEF starts the browser pages' renderer, GPU and utility
//! processes from: Ljós's `ljos-webengine-helper`, built here so it ships
//! beside hal-c2-ljos (and a test's `deps/`), where Ljós looks for it. On
//! macOS it runs as each helper application of the app's bundle.

fn main() {
    // On macOS the helper is `<Name> Helper.app` inside the bundle, and
    // loads CEF's framework from there before calling it.
    #[cfg(target_os = "macos")]
    let _framework = {
        let exe = std::env::current_exe().expect("the helper's path");
        if ljos_webengine::mac_bundle::framework_of_helper(&exe).is_none() {
            eprintln!(
                "ljos-webengine-helper: {} is not a helper application of a bundle with CEF's \
                 framework",
                exe.display()
            );
            std::process::exit(1);
        }
        let loader = cef::library_loader::LibraryLoader::new(&exe, true);
        if !loader.load() {
            eprintln!("ljos-webengine-helper: CEF's framework did not load");
            std::process::exit(1);
        }
        loader
    };
    let _ = cef::api_hash(cef::sys::CEF_API_VERSION_LAST, 0);
    let args = cef::args::Args::new();
    let code = cef::execute_process(Some(args.as_main_args()), None, std::ptr::null_mut());
    std::process::exit(code.max(0));
}
