# CPReady

CPReady is an application for the [OpenEarable](https://open-earable.teco.edu).
It helps the user while performing CPR.

## Features
- Measures the frequency with which the user is currently performing CPR.
- Gives feedback according to the current frequency.
- Gives the user audio or visual support for staying within the recommended frequency range.
- Optionally supports mouth-to-mouth resuscitation by prompting the user to do so at the recommended times.

## Visual support
By default, a visual support is shown.
This visual support consists of an animation that shows an CPR procedure with a frequency of 110 bpm.
If the audio support is activated, the visual support is deactivated.

## Audio Support
It is possible to enable audio support.
For this feature to work, an audio file (.wav format) named "frequency.wav" needs to be on the SD card inserted into the earable.
This file needs to contain the metronome sound in the desired frequency.
An exemplary file is provided in the assets folder.
If the prerequisites are met, the audio support can be enabled with a button while doing CPR.

## Mouth-to-mouth resuscitation
Optionally, the app can prompt the user to do mouth-to-mouth resuscitation.
This is done by showing a pop-up dialogue after every 30 pushes.

## Tests
Since I only have an windows laptop and because of the gradle error, I could not test on an Emulator or physical android device.
The app is therefore only tested on Edge(Web) and Chrome(Web).