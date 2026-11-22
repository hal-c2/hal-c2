import QtQuick

// The frames an Actor shows while it stands at a goal with this pose's name.
QtObject {
    property string name: ""
    property var frames: [0]
    // Milliseconds a frame, or one number per frame.
    property var every: 300

    // The frame at `time`, in world milliseconds.
    function frameAt(time) {
        if (frames.length < 2)
            return frames[0] ?? 0;
        if (typeof every === "number")
            return frames[Math.floor(time / every) % frames.length];
        let round = 0;
        for (let i = 0; i < frames.length; i++)
            round += every[i];
        let left = time % round;
        for (let i = 0; i < frames.length; i++) {
            left -= every[i];
            if (left < 0)
                return frames[i];
        }
        return frames[0];
    }
}
