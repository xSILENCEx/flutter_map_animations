import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/plugin_api.dart';
import 'package:flutter_map_animations/src/animation_extensions.dart';
import 'package:flutter_map_animations/src/lat_lng_tween.dart';
import 'package:latlong2/latlong.dart';

typedef _MovementCallback = bool Function(
  CurvedAnimation animation,
  LatLngTween latLngTween,
  Tween<double> zoomTween,
  Tween<double> rotateTween,
  AnimationId animationId,
);

/// A wrap around [MapController] that provides animated methods.
class AnimatedMapController {
  /// Creates a [MapController] that provides animated methods.
  AnimatedMapController({
    required this.vsync,
    MapController? mapController,
    this.duration = const Duration(milliseconds: 500),
    this.curve = Curves.fastOutSlowIn,
  })  : mapController = mapController ?? MapController(),
        _internal = mapController == null;

  /// The vsync of the animation.
  final TickerProvider vsync;

  /// Implementation of the map controller that will be used to trigger
  /// movements.
  ///
  /// Defaults to a new [MapController] which should be a [MapControllerImpl].
  ///
  /// If created internally (i.e. not passed as a parameter), it will be
  /// disposed when [dispose] is called.
  final MapController mapController;

  /// Whether the map controller was created internally or passed as a
  /// parameter. Used to know if the map controller should be disposed or not
  /// by the animated map controller.
  final bool _internal;

  /// The duration of the animation.
  final Duration duration;

  /// The curve of the animation.
  final Curve curve;

  /// Current rotation of the map.
  double get rotation {
    double effectiveRotation = mapController.rotation;
    if (effectiveRotation >= 360) {
      effectiveRotation -= 360;
    } else if (effectiveRotation < 0) {
      effectiveRotation += 360;
    }
    return effectiveRotation;
  }

  /// Controller of the current animation.
  AnimationController? _animationController;

  void dispose() {
    final isAnimating = _animationController?.isAnimating ?? false;
    if (isAnimating) {
      _animationController?.stop();
    }
    _animationController?.dispose();

    // Dispose the map controller if it was created internally.
    if (_internal) {
      mapController.dispose();
    }
  }

  /// Animate the map to [dest] with an optional [zoom] level and [rotation] in
  /// degrees.
  ///
  /// If specified, [zoom] must be greater or equal to 0.
  ///
  /// {@template animated_map_controller.animate_to.curve}
  /// If [curve] is not specified, the one specified in the constructor will be
  /// used.
  /// {@endtemplate}
  Future<void> animateTo({
    LatLng? dest,
    double? zoom,
    double? rotation,
    Curve? curve,
    Duration? duration,
    String? customId,
  }) {
    if (zoom != null && zoom < 0) {
      throw ArgumentError.value(
        zoom,
        'zoom',
        'Zoom must be greater or equal to 0',
      );
    }

    final effectiveDest = dest ?? mapController.center;
    final effectiveZoom = zoom ?? mapController.zoom;
    final effectiveRotation = rotation ?? this.rotation;
    final latLngTween = LatLngTween(
      begin: mapController.center,
      end: effectiveDest,
    );
    final zoomTween = Tween<double>(
      begin: mapController.zoom,
      end: effectiveZoom,
    );
    double startRotation = this.rotation;
    double endRotation = effectiveRotation;

    // If the difference between the bearings is greater than 180 degrees,
    // add or subtract 360 degrees to one of them to make the shortest
    // rotation direction counterclockwise.
    final diff = endRotation - startRotation;
    if (diff > 180.0) {
      startRotation += 360.0;
    } else if (diff < -180.0) {
      endRotation += 360.0;
    }

    final rotateTween = Tween<double>(
      begin: startRotation,
      end: endRotation,
    );

    // Determine the callback for movement. If no movement will occur return
    // immediately.
    final bool hasRotation = rotation != null && rotation != this.rotation;
    final bool hasMovement =
        (dest != null && dest != mapController.center) || (zoom != null && zoom != mapController.zoom);
    final movementCallback = _movementCallback(hasMovement: hasMovement, hasRotation: hasRotation);
    if (movementCallback == null) return Future.value();

    // This controller will be disposed when the animation is completed.
    final animationController = AnimationController(
      vsync: vsync,
      duration: duration ?? this.duration,
    );
    _animationController = animationController;

    final animation = CurvedAnimation(
      parent: animationController,
      curve: curve ?? this.curve,
    )..onEnd(() {
        animationController.dispose();
        _animationController = null;
      });

    AnimationId animationId = AnimationId(
      destLocation: effectiveDest,
      destZoom: effectiveZoom,
      customId: customId,
    );

    bool hasTriggeredMove = false;
    bool animationCompleted = false;

    animationController.addListener(() {
      // The animation calls this listener with value 1.0 twice. Once when the
      // value is 1.0 but isCompleted is false and again when it is still 1.0
      // and isCompleted is true. This check ensures we don't trigger a
      // duplicate movement but also, more importantly, that we trigger the
      // final movement with the finished id exactly once.
      if (animationCompleted) return;
      animationCompleted |= animation.value == 1.0;

      animationId = animationId.copyWith(
        moveId: AnimatedMoveId.fromAnimationAndTriggeredMove(
          animationIsCompleted: animationCompleted,
          hasTriggeredMove: hasTriggeredMove,
        ),
      );

      hasTriggeredMove |= movementCallback(
        animation,
        latLngTween,
        zoomTween,
        rotateTween,
        animationId,
      );
    });

    return animationController.forward();
  }

  // Determine what MapController method should be called based on whether
  // there is movement and/or rotation. If there is neither movement nor
  // rotation null is returned.
  _MovementCallback? _movementCallback({
    required bool hasMovement,
    required bool hasRotation,
  }) {
    if (hasMovement && hasRotation) {
      return (animation, latLngTween, zoomTween, rotateTween, animationId) {
        final result = mapController.moveAndRotate(
          latLngTween.evaluate(animation),
          zoomTween.evaluate(animation),
          rotateTween.evaluate(animation),
          id: animationId.id,
        );
        return result.moveSuccess || result.rotateSuccess;
      };
    } else if (hasMovement) {
      return (animation, latLngTween, zoomTween, rotateTween, animationId) => mapController.move(
            latLngTween.evaluate(animation),
            zoomTween.evaluate(animation),
            id: animationId.id,
          );
    } else if (hasRotation) {
      return (animation, latLngTween, zoomTween, rotateTween, animationId) => mapController.rotate(
            rotateTween.evaluate(animation),
            id: animationId.id,
          );
    } else {
      return null;
    }
  }

  /// Center the map on [point] with an optional [zoom] level.
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  Future<void> centerOnPoint(
    LatLng point, {
    double? zoom,
    Curve? curve,
    String? customId,
  }) {
    return animateTo(dest: point, zoom: zoom, curve: curve, customId: customId);
  }

  /// Apply a rotation of [degree] to the current rotation.
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  Future<void> animatedRotateFrom(
    double degree, {
    Curve? curve,
    String? customId,
  }) {
    return animateTo(
      rotation: rotation + degree,
      curve: curve,
      customId: customId,
    );
  }

  /// Set the rotation to [degree].
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  Future<void> animatedRotateTo(
    double degree, {
    Curve? curve,
    String? customId,
  }) {
    return animateTo(rotation: degree, curve: curve, customId: customId);
  }

  /// Reset the rotation to 0.
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  Future<void> animatedRotateReset({Curve? curve, String? customId}) {
    return animateTo(rotation: 0, curve: curve, customId: customId);
  }

  /// Add one level to the current zoom level.
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  Future<void> animatedZoomIn({Curve? curve, String? customId}) {
    return animateTo(
      zoom: mapController.zoom + 1,
      curve: curve,
      customId: customId,
    );
  }

  /// Remove one level to the current zoom level.
  ///
  /// If the current zoom level is 0, nothing will happen.
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  FutureOr<void> animatedZoomOut({Curve? curve, String? customId}) {
    final newZoom = mapController.zoom - 1;
    if (newZoom < 0) return null;

    return animateTo(zoom: newZoom, curve: curve, customId: customId);
  }

  /// Set the zoom level to [newZoom].
  ///
  /// [newZoom] must be greater or equal to 0.
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  Future<void> animatedZoomTo(
    double newZoom, {
    Curve? curve,
    String? customId,
  }) {
    return animateTo(zoom: newZoom, curve: curve, customId: customId);
  }

  /// Will use the [centerZoomFitBounds] method with [bounds] and [options] to
  /// calculate the center and zoom level and then animate to that position.
  ///
  /// If [options] is not specified, it will use a default padding of 12.
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  Future<void> animatedFitBounds(
    LatLngBounds bounds, {
    FitBoundsOptions? options,
    Curve? curve,
    String? customId,
  }) {
    final localOptions = options ?? const FitBoundsOptions(padding: EdgeInsets.all(12));
    final centerZoom = mapController.centerZoomFitBounds(
      bounds,
      options: localOptions,
    );

    return animateTo(
      dest: centerZoom.center,
      zoom: centerZoom.zoom,
      curve: curve,
      customId: customId,
    );
  }

  /// Will use the [LatLngBounds.fromPoints] method to calculate the bounds of
  /// the [points] and then use the [animatedFitBounds] method to animate to
  /// that position.
  ///
  /// If [options] is not specified, it will use a default padding of 12.
  ///
  /// {@macro animated_map_controller.animate_to.curve}
  Future<void> centerOnPoints(
    List<LatLng> points, {
    FitBoundsOptions? options,
    Curve? curve,
    String? customId,
  }) {
    final bounds = LatLngBounds.fromPoints(points);

    return animatedFitBounds(
      bounds,
      options: options,
      curve: curve,
      customId: customId,
    );
  }
}
