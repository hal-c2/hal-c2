//! The files a drop or a paste hands the composer, as desktop-qt's
//! ShellBridge reads them: an image as its bytes ({name, mimeType, base64}),
//! any other file by its path ({name, mimeType, path}), and a copied
//! picture as "image.png".

use std::io::Cursor;
use std::path::Path;

use base64::Engine as _;
use serde_json::json;

use crate::json::Json;

/// The largest image a prompt carries (desktop-qt's 10 MiB).
pub const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024;
/// The largest other file (50 MiB).
pub const MAX_FILE_BYTES: u64 = 50 * 1024 * 1024;

/// What a file is, from its name: QMimeDatabase without its content
/// sniffing.
pub fn mime_of(path: &str) -> &'static str {
    let extension = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" | "jpe" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        "ico" => "image/vnd.microsoft.icon",
        "tif" | "tiff" => "image/tiff",
        "avif" => "image/avif",
        "heic" => "image/heic",
        "pdf" => "application/pdf",
        "md" | "markdown" | "mdown" | "mkd" | "mdx" => "text/markdown",
        "txt" | "log" => "text/plain",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        "css" => "text/css",
        "xml" => "application/xml",
        "json" => "application/json",
        "yaml" | "yml" => "application/yaml",
        "toml" => "application/toml",
        "js" | "mjs" | "cjs" => "text/javascript",
        "ts" | "mts" | "cts" => "text/x-typescript",
        "tsx" | "jsx" => "text/plain",
        "rs" => "text/rust",
        "py" => "text/x-python",
        "rb" => "application/x-ruby",
        "go" => "text/x-go",
        "c" | "h" => "text/x-csrc",
        "cpp" | "cc" | "cxx" | "hpp" | "hh" => "text/x-c++src",
        "java" => "text/x-java",
        "kt" | "kts" => "text/x-kotlin",
        "swift" => "text/x-swift",
        "ex" | "exs" => "text/x-elixir",
        "sh" | "bash" | "zsh" => "application/x-shellscript",
        "sql" => "application/sql",
        "qml" => "text/x-qml",
        "zip" => "application/zip",
        "gz" => "application/gzip",
        "tar" => "application/x-tar",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        _ => "application/octet-stream",
    }
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// An image at `path` as the composer takes it; None for anything else, one
/// over [`MAX_IMAGE_BYTES`] or one that cannot be read.
pub fn read_image(path: &str) -> Option<Json> {
    let mime = mime_of(path);
    if !mime.starts_with("image/") {
        return None;
    }
    let file = Path::new(path);
    if std::fs::metadata(file).ok()?.len() > MAX_IMAGE_BYTES {
        return None;
    }
    let bytes = std::fs::read(file).ok()?;
    Some(json!({
        "name": name_of(file),
        "mimeType": mime,
        "base64": base64::engine::general_purpose::STANDARD.encode(bytes),
    }))
}

/// A file at `path`: an image as [`read_image`] has it, any other by its
/// path; None for a folder, an empty file or one over the limits.
pub fn read_attachment(path: &str) -> Option<Json> {
    let file = Path::new(path);
    let meta = std::fs::metadata(file).ok()?;
    if !meta.is_file() {
        return None;
    }
    let mime = mime_of(path);
    if mime.starts_with("image/") {
        return read_image(path);
    }
    if meta.len() < 1 || meta.len() > MAX_FILE_BYTES {
        return None;
    }
    let absolute = std::path::absolute(file).ok()?;
    Some(json!({
        "name": name_of(file),
        "mimeType": mime,
        "path": absolute.to_string_lossy(),
    }))
}

/// A copied picture (RGBA rows) as the PNG "image.png"; None when it does
/// not encode or is over [`MAX_IMAGE_BYTES`].
pub fn pasted_image(width: usize, height: usize, rgba: Vec<u8>) -> Option<Json> {
    let image = image::RgbaImage::from_raw(width.try_into().ok()?, height.try_into().ok()?, rgba)?;
    let mut png = Cursor::new(Vec::new());
    image.write_to(&mut png, image::ImageFormat::Png).ok()?;
    let png = png.into_inner();
    if png.len() as u64 > MAX_IMAGE_BYTES {
        return None;
    }
    Some(json!({
        "name": "image.png",
        "mimeType": "image/png",
        "base64": base64::engine::general_purpose::STANDARD.encode(png),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> tempfile::TempDir {
        tempfile::tempdir().expect("a scratch folder")
    }

    #[test]
    fn mime_by_extension() {
        assert_eq!(mime_of("/a/B.PNG"), "image/png");
        assert_eq!(mime_of("notes.md"), "text/markdown");
        assert_eq!(mime_of("Makefile"), "application/octet-stream");
    }

    #[test]
    fn reads_images_and_files() {
        let dir = scratch();
        let png = dir.path().join("a.png");
        std::fs::write(&png, [1u8, 2, 3]).expect("write");
        let text = dir.path().join("b.rs");
        std::fs::write(&text, "fn main() {}").expect("write");
        let empty = dir.path().join("c.txt");
        std::fs::write(&empty, "").expect("write");

        let image = read_attachment(&png.to_string_lossy()).expect("the image");
        assert_eq!(image["base64"], "AQID");
        assert_eq!(image["name"], "a.png");
        let file = read_attachment(&text.to_string_lossy()).expect("the file");
        assert_eq!(file["path"], text.to_string_lossy().as_ref());
        assert_eq!(file["mimeType"], "text/rust");
        assert!(read_attachment(&empty.to_string_lossy()).is_none());
        assert!(read_attachment(&dir.path().to_string_lossy()).is_none());
        // Only images read as images.
        assert!(read_image(&text.to_string_lossy()).is_none());
    }

    #[test]
    fn pasted_picture_is_png() {
        let image = pasted_image(1, 1, vec![255, 0, 0, 255]).expect("a png");
        assert_eq!(image["name"], "image.png");
        assert!(
            image["base64"]
                .as_str()
                .is_some_and(|b| b.starts_with("iVBOR"))
        );
        assert!(pasted_image(2, 2, vec![0; 4]).is_none());
    }
}
