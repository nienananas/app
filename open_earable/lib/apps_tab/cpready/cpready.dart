import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_timer_countdown/flutter_timer_countdown.dart';
import 'package:open_earable/apps_tab/cpready/model/data.dart';
import 'package:open_earable/apps_tab/cpready/utils.dart';
import 'package:open_earable/apps_tab/cpready/widgets/cpr_instruction_view.dart';
import 'package:open_earable/apps_tab/cpready/widgets/cpr_standard_button.dart';
import 'package:open_earable/apps_tab/cpready/widgets/cpr_start_button.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:simple_kalman/simple_kalman.dart';

/// App that helps the user when performing CPR
///
/// It provides functionality for measuring the frequency of the CPR procedure.
/// Also it supports mouth-to-mouth procedure and actively prompts the user to do
/// so if the feature is activated.
/// Additionally a metronome is implemented which can give the user an
/// audible support for performing CPR with a frequency of 110 bpm.
class CPReady extends StatefulWidget {
  const CPReady(this._openEarable, {super.key});

  final OpenEarable _openEarable;

  @override
  State<CPReady> createState() => _CPReadyState();
}

class _CPReadyState extends State<CPReady> {
  /// The alpha parameter for the exponential smoothing
  final double _exponentialSmoothingAlpha = 0.5;

  /// The threshold for the acceleration after which a movement should be considered a push
  final double _accelerationThreshold = 2;

  /// Error measure for the Kalman filter.
  final _errorMeasureAcc = 5.0;

  /// Sampling rate time.
  final double _samplingRate = 30;

  /// Gravity constant [m / (s^2)].
  final double _gravity = 9.81;

  ///Constant for the amounts of pushes between mouth-to-mouth sequences
  final int _mouthToMouthInterval = 30;

  /// The subscription to the imu data.
  StreamSubscription? _imuSubscription;

  /// Flag to indicate if an OpenEarable device is connected.
  bool _earableConnected = false;

  /// Kalman filters for accelerometer data.
  late SimpleKalman _kalmanX, _kalmanY, _kalmanZ;

  /// Accelerations.
  double _accX = 0.0;
  double _accY = 0.0;
  double _accZ = 0.0;

  /// The current acceleration magnitude
  double _currentAcc = 0.0;

  /// Current frequency of up and down movements in Hz
  double _currentFrequency = 0;

  /// [DateTime] of the last push that was recorded
  DateTime? _lastPush;

  /// Bool storing if there was a currently a push detected
  bool _detectedPush = false;

  /// Bool storing if a cpr is currently executed.
  bool _doingCPR = false;

  /// Instruction currently given to the user
  CPRInstruction _currentInstruction = CPRInstruction.fine;

  /// Timer for the guided CPR
  Timer? _timer;

  /// Bool for storing if mouth-to-mouth is activated
  bool _mouthToMouth = true;

  /// Counter for counting how many pushes were made
  int _pushCounter = 0;

  @override
  void initState() {
    super.initState();
    // Set up listeners for sensor data.
    if (widget._openEarable.bleManager.connected) {
      // Set the configuration for the OpenEarable device
      widget._openEarable.sensorManager.writeSensorConfig(
        OpenEarableSensorConfig(
          sensorId: 0,
          samplingRate: _samplingRate,
          latency: 0,
        ),
      );
      _initializeKalmanFilters();
      _setupSensorListeners();
      _earableConnected = true;
    }
  }

  @override
  void dispose() {
    super.dispose();
    _imuSubscription?.cancel();
    _timer?.cancel();
    if (_earableConnected) {
      widget._openEarable.audioPlayer.setState(AudioPlayerState.stop);
    }
  }

  /// Sets up listeners to receive sensor data from the OpenEarable device.
  void _setupSensorListeners() {
    _imuSubscription = widget._openEarable.sensorManager
        .subscribeToSensorData(0)
        .listen((data) {
      // Only process sensor data if the user is currently performing CPR.
      if (_doingCPR) {
        _processSensorData(data);
      }
    });
  }

  /// Processes the received sensor [data] and updates the frequency.
  /// The frequency is only updated if a new push is detected.
  void _processSensorData(Map<String, dynamic> data) {
    setState(() {
      /// Kalman filtered acceleration data
      _accX = _kalmanX.filtered(data["ACC"]["X"]);
      _accY = _kalmanY.filtered(data["ACC"]["Y"]);
      _accZ = _kalmanZ.filtered(data["ACC"]["Z"]);

      // Calculates the current magnitude of acceleration.
      _currentAcc =
          _accZ.sign * sqrt(_accX * _accX + _accY * _accY + _accZ * _accZ);

      // Need to subtract gravity to get real movement and not background force.
      _currentAcc -= _gravity;
    });

    if (_currentAcc > _accelerationThreshold && !_detectedPush) {
      //If there is enough magnitude assume there is currently a push
      _updateFrequency();
      setState(() {
        _detectedPush = true;
      });
    } else if (_currentAcc < 0) {
      //Upward movement
      setState(() {
        _detectedPush = false;
      });
    }
  }

  /// Updates the frequency of the CPR
  void _updateFrequency() {
    var currentTime = DateTime.now();
    if (_lastPush == null) {
      //If this is the first recorded push.
      setState(() {
        _lastPush = currentTime;
        _pushCounter++;
      });
      return;
    }
    //difference is the duration for the last up and down movement
    int difference = currentTime.difference(_lastPush!).inMilliseconds;

    //Converting the time needed for one up and down movement to a frequency [Hz].
    //The calculated frequency is also exponentially smoothened with the previous values.
    //Source exponential smoothing: https://en.wikipedia.org/wiki/Exponential_smoothing
    //Should only be calculated if the difference was big enough so that false positives are ignored.
    if (difference > 20) {
      setState(() {
        _currentFrequency = _exponentialSmoothingAlpha * (1000 / difference) +
            (1 - _exponentialSmoothingAlpha) * _currentFrequency;
        _lastPush = currentTime;
        _pushCounter++;

        if (_pushCounter == _mouthToMouthInterval) {
          _pushCounter = 0;
          if (_mouthToMouth) {
            _mouthToMouthSequence();
          }
        }
      });
      _updateInstruction();
    }
  }

  /// Updates the instruction given to the user based on the frequency measured
  /// by the earable, with which they are currently giving CPR.
  ///
  /// The recommend CPR frequency is between 100 and 120 bpm
  /// (Source: [NHS](https://www.nhs.uk/conditions/first-aid/cpr/#:~:text=Keeping%20your%20hands%20on%20their,as%20long%20as%20you%20can.))
  void _updateInstruction() {
    setState(() {
      if (_currentFrequency < (70 / 60)) {
        _currentInstruction = CPRInstruction.muchFaster;
      } else if (_currentFrequency < (100 / 60)) {
        _currentInstruction = CPRInstruction.faster;
      } else if (_currentFrequency > (150 / 60)) {
        _currentInstruction = CPRInstruction.muchSlower;
      } else if (_currentFrequency > (120 / 60)) {
        _currentInstruction = CPRInstruction.slower;
      } else {
        _currentInstruction = CPRInstruction.fine;
      }
    });
  }

  /// Initializes Kalman filters for acceleration data.
  void _initializeKalmanFilters() {
    _kalmanX = SimpleKalman(
      errorMeasure: _errorMeasureAcc,
      errorEstimate: _errorMeasureAcc,
      q: 0.9,
    );
    _kalmanY = SimpleKalman(
      errorMeasure: _errorMeasureAcc,
      errorEstimate: _errorMeasureAcc,
      q: 0.9,
    );
    _kalmanZ = SimpleKalman(
      errorMeasure: _errorMeasureAcc,
      errorEstimate: _errorMeasureAcc,
      q: 0.9,
    );
  }

  /// Initializes a mouth to mouth sequence.
  ///
  /// Shows a dialog that requests the user to do a mouth-to-mouth procedure.
  void _mouthToMouthSequence() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext builderContext) {
        //Future for closing the dialog
        Future.delayed(Duration(seconds: 4), () {
          if (builderContext.mounted) {
            Navigator.of(builderContext).pop();
          }
          setState(() {
            _lastPush = null;
            _pushCounter = 0;
          });
        });

        return AlertDialog(
          title: Text(
            'Time for mouth-to-mouth!',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          content: SingleChildScrollView(
            child: Column(
              children: [
                Image(
                  image: AssetImage(
                    "lib/apps_tab/cpready/assets/mouthtomouth.png",
                  ),
                ),
                SizedBox(
                  height: 5,
                ),
                Text(
                  "If you want to deactivate this feature, do so with the slider",
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Starts or stops a timer for the metronome.
  /// Due to the asynchronous communication and jitter, the metronome does not
  /// play a perfect frequency but can still help.
  void _startStopMetronomeTimer() {
    if (_timer == null) {
      //Sets up a timer that will play a tone with a frequency of approx 110 bpm
      _timer = Timer.periodic(
        Duration(milliseconds: 545),
        (Timer t) {
          if (_earableConnected) {
            widget._openEarable.audioPlayer.setState(AudioPlayerState.start);
            widget._openEarable.audioPlayer.setState(AudioPlayerState.pause);
          }
        },
      );

      if (_earableConnected) {
        widget._openEarable.audioPlayer.frequency(1, 440, 0.2);
      }
    } else {
      if (_earableConnected) {
        widget._openEarable.audioPlayer.setState(AudioPlayerState.pause);
      }
      _timer!.cancel();
      _timer = null;
    }
  }

  ///Starts or stops a CPR procedure.
  void _startStopCPR() {
    if (_doingCPR) {
      //Stop CPR
      setState(() {
        _doingCPR = false;
        _lastPush = null;
      });
      return;
    }

    var theme = Theme.of(context);

    //Start CPR with a countdown
    showDialog(
      barrierDismissible: false,
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          "Get in position!",
          style: TextStyle(color: Colors.white, fontSize: 30),
          textScaler: TextScaler.linear(textScaleFactor(context)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TimerCountdown(
              format: CountDownTimerFormat.secondsOnly,
              timeTextStyle: theme.textTheme.displayLarge,
              secondsDescription: "",
              endTime: DateTime.now().add(
                const Duration(
                  seconds: 03,
                ),
              ),
              onEnd: () {
                Navigator.pop(context);
                setState(() {
                  _doingCPR = true;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(3.0),
          child: ImageIcon(
            AssetImage("lib/apps_tab/cpready/assets/logo_outlined.png"),
            color: Colors.black,
          ),
        ),
        title: const Text("CPReady"),
        backgroundColor: Colors.redAccent,
      ),
      body: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: 10,
            ),
            Visibility(
              // Show error message if no OpenEarable device is connected.
              visible: !_earableConnected,
              maintainState: true,
              maintainAnimation: true,
              child: Column(
                children: [
                  Icon(
                    Icons.warning,
                    color: Colors.red,
                    size: 40,
                  ),
                  Text(
                    "No Earable Connected",
                    style: TextStyle(
                      color: Colors.red,
                      fontSize: 30,
                    ),
                    textScaler: TextScaler.linear(textScaleFactor(context)),
                  ),
                  SizedBox(
                    height: 20,
                  ),
                ],
              ),
            ),
            _doingCPR ? _buildCprScreen() : _buildStartScreen(),
          ],
        ),
      ),
    );
  }

  /// Method that returns the widget that is shown when the user is not doing CPR
  Widget _buildStartScreen() {
    double mainButtonSize =
        min(max(MediaQuery.sizeOf(context).width / 2, 300), 500);

    return Column(
      children: [
        CprStartButton(
          onPressed: _startStopCPR,
          size: mainButtonSize,
        ),
        SizedBox(
          height: 20,
        ),
        Text(
          "First call emergency agencies before performing CPR",
          style: TextStyle(color: Colors.white, fontSize: 30),
          textScaler: TextScaler.linear(textScaleFactor(context)),
        ),
      ],
    );
  }

  /// Method that returns the widget that is shown when the user is performing CPR
  Widget _buildCprScreen() {
    return Column(
      children: [
        Center(
          child: Container(
            margin: const EdgeInsets.all(5.0),
            padding: const EdgeInsets.all(2.0),
            decoration: BoxDecoration(
              border: Border.all(
                width: 1.0,
                color: Colors.redAccent,
              ),
              borderRadius: const BorderRadius.all(
                Radius.circular(10.0) //
                ,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                Switch(
                  value: _mouthToMouth,
                  onChanged: (value) {
                    setState(() {
                      _mouthToMouth = value;
                    });
                  },
                ),
                SizedBox(
                  width: 5,
                ),
                Text(
                  "Mouth-to-mouth",
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                Visibility(
                  visible: _mouthToMouth,
                  child: Expanded(
                    child: Text(
                      "In ${max(0, _mouthToMouthInterval - _pushCounter)}",
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),
                SizedBox(
                  width: 5,
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            SizedBox(
              width: 5,
            ),
            Expanded(
              flex: 1,
              child: CprStandardButton(
                onPressed: _startStopCPR,
                label: "Stop CPR",
              ),
            ),
            SizedBox(
              width: 10,
            ),
            Expanded(
              flex: 1,
              child: CprStandardButton(
                onPressed: _startStopMetronomeTimer,
                label: _timer == null ? "Start Metronome" : "Stop Metronome",
              ),
            ),
            SizedBox(
              width: 5,
            ),
          ],
        ),
        CprInstructionView(instruction: _currentInstruction),
        Text(
          "Current frequency: ${toBPM(_currentFrequency).round()}",
          style: TextStyle(fontSize: 40),
          textScaler: TextScaler.linear(textScaleFactor(context)),
        ),
        SizedBox(
          height: 20,
        ),
        Text(
          "The recommend frequency is between 100 and 120 bpm",
          style: TextStyle(fontSize: 30),
          textScaler: TextScaler.linear(textScaleFactor(context)),
        ),
      ],
    );
  }
}
