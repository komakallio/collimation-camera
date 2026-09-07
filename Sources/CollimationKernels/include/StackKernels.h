#ifndef COLLIMATION_STACK_KERNELS_H
#define COLLIMATION_STACK_KERNELS_H

#include <stdint.h>

void collimation_accumulate_integer(
    const uint16_t *pixels,
    int width,
    int height,
    int dx,
    int dy,
    float *sum,
    float *weight
);

void collimation_accumulate_bilinear(
    const uint16_t *pixels,
    int width,
    int height,
    float dx,
    float dy,
    float *sum,
    float *weight
);

int collimation_moment_centroid(
    const uint16_t *pixels,
    int width,
    int height,
    int cx,
    int cy,
    int half_window,
    double *out_x,
    double *out_y
);

#endif
