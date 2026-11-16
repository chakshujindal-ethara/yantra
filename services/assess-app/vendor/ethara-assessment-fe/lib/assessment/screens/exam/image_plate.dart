// ONE WAY TO PUT A THIRD-PARTY IMAGE ON SCREEN: as a real `<img>` element.
//
// WHY THIS EXISTS, AND WHY IT MIRRORS `video_plate.dart`. Pasted video URLs
// worked flawlessly while pasted image URLs drew a dead plate, and the reason
// was never the URL - it was the rendering path. A video is a DOM element in a
// platform view, so the BROWSER loads it as an ordinary subresource; an image
// went through `Image.network`, which fetches bytes over XHR and therefore needs
// the far host to send `Access-Control-Allow-Origin`. Almost no image host does.
//
// A browser needs CORS to READ an image's pixels, not to SHOW it. So an `<img>`
// element displays what an XHR cannot fetch, which is the whole of the fix.
//
// `Image.network(webHtmlElementStrategy: fallback)` is Flutter's own version of
// this and is genuinely useful, but it is a RETRY: bytes first, element only
// once the fetch has already failed. That is one wasted round trip per image,
// and it routes a cross-origin still through `WebImageInfo`, whose `.image`
// getter throws - so anything downstream that measures pixels breaks. Going
// element-first for foreign origins avoids both.
//
// The facade re-exports one of two halves and defines nothing itself, exactly as
// `video_plate.dart` does. Callers import this file only.
library;

export 'image_plate_stub.dart'
    if (dart.library.js_interop) 'image_plate_web.dart';
