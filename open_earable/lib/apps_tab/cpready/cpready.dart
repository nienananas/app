import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_timer_countdown/flutter_timer_countdown.dart';
import 'package:open_earable/apps_tab/cpready/model/data.dart';
import 'package:open_earable/apps_tab/cpready/utils.dart';
import 'package:open_earable/apps_tab/cpready/widgets/cpr_instruction_view.dart';
import 'package:open_earable/apps_tab/cpready/widgets/cpr_start_button.dart';
import 'package:open_earable_flutter/open_earable_flutter.dart';
import 'package:simple_kalman/simple_kalman.dart';

class CPReady extends StatefulWidget {
  const CPReady(this._openEarable, {super.key});

  final OpenEarable _openEarable;

  @override
  State<CPReady> createState() => _CPReadyState();
}

class _CPReadyState extends State<CPReady> {
  /// The subscription to the imu data.
  StreamSubscription? _imuSubscription;

  /// Flag to indicate if an OpenEarable device is connected.
  bool _earableConnected = false;

  /// Error measure for the Kalman filter.
  final _errorMeasureAcc = 5.0;

  /// Kalman filters for accelerometer data.
  late SimpleKalman _kalmanX, _kalmanY, _kalmanZ;

  /// Sampling rate time.
  final double _samplingRate = 30;

  /// Gravity constant [m / (s^2)].
  final double _gravity = 9.81;

  /// Accelerations.
  double _accX = 0.0;
  double _accY = 0.0;
  double _accZ = 0.0;

  /// The current acceleration magnitude
  double _currentAcc = 0.0;

  /// Current frequency of up and down movements in Hz
  double _currentFrequency = 100 / 60;

  /// The alpha parameter for the exponential smoothing
  final double _exponentialSmoothingAlpha = 0.7;

  /// The threshold for the acceleration after which a movement should be considered a push
  final double _accelerationThreshold = 2;

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

  /// Bool storing if a playback should be played
  bool _playingTone = false;

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

    _timer = Timer.periodic(
      Duration(milliseconds: 500),
          (Timer t) {_playTone();},
    );
  }

  @override
  void dispose() {
    super.dispose();
    _imuSubscription?.cancel();
    _timer!.cancel();
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

  void _playTone() {
    if (_earableConnected && _playingTone) {
      widget._openEarable.audioPlayer.setState(AudioPlayerState.start);
      widget._openEarable.audioPlayer.setState(AudioPlayerState.pause);
    }
  }

  void _startStopTimer() {
    //Sets up a timer that will play a tone with a frequency of 120 bpm
    if (_playingTone) {
      _playingTone = false;
      widget._openEarable.audioPlayer.setState(AudioPlayerState.pause);
    } else {
      _playingTone = true;
      widget._openEarable.audioPlayer.frequency(1, 440, 0.2);
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
          style: theme.textTheme.displaySmall,
        ),
        content: Column(
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
            Text(
              "First call emergency agencies before performing CPR",
              style: theme.textTheme.displaySmall,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    double mainButtonSize =
        min(max(MediaQuery.sizeOf(context).width / 2, 300), 500);

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
            ElevatedButton(onPressed: _startStopTimer, child: Text("Frequency")),
            Visibility(
              // Show error message if no OpenEarable device is connected.
              visible: !_earableConnected,
              maintainState: true,
              maintainAnimation: true,
              child: Column(
                children: [
                  Text(
                    "No Earable Connected",
                    style: TextStyle(
                      color: Colors.red,
                      fontSize: 50,
                    ),
                  ),
                  SizedBox(
                    height: 20,
                  ),
                ],
              ),
            ),
            CprStartButton(
              doingCPR: _doingCPR,
              onPressed: _startStopCPR,
              size: mainButtonSize,
            ),
            Visibility(
              // The values measured while doing CPR
              visible: _doingCPR,
              maintainState: true,
              maintainAnimation: true,
              child: Column(
                children: [
                  CPRInstructionView(instruction: _currentInstruction),
                  Text("Current frequency: ${toBPM(_currentFrequency).round()}",
                      style: TextStyle(fontSize: 40),
                      textScaler: TextScaler.linear(textScaleFactor(context))),
                  SizedBox(
                    height: 20,
                  ),
                  Text(
                    "The recommend frequency is between 100 and 120 bpm",
                    style: TextStyle(fontSize: 30),
                    textScaler: TextScaler.linear(textScaleFactor(context)),
                  ),
                  Text(
                    "Current vertical acceleration: ${_currentAcc.toStringAsFixed(4)}",
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
