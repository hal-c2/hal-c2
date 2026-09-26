# `@hal-c2/opentui-image`

HAL-C2's bounded image preview decoder and Kitty clipboard adapter.

`decodeImage` uses Sharp to rotate, resize, and encode an attachment as a bounded
PNG preview. HAL-C2 passes that encoded source directly to OpenTUI's built-in
`<image>` element. OpenTUI owns decoding, layout, clipping, and terminal output.

The package keeps two HAL-C2-specific pieces:

- bounded Sharp decoding for formats accepted by chat attachments;
- Kitty clipboard reads, including tmux passthrough for remote sessions.

```tsx
import { decodeImage } from "@hal-c2/opentui-image";

const preview = await decodeImage(encoded, { maxWidth: 720, maxHeight: 480 });

<image source={preview.source} width={40} height={12} fit="fill" />;
```
