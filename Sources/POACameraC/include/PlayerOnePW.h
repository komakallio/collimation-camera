/****************************************************************************
** Types-only excerpt of the Player One Phoenix Filter Wheel SDK header.
** Function symbols are resolved at runtime via dlopen; they are intentionally
** omitted here so this module does not create link-time dependencies.
** Copyright (C) Player One Astronomy Co., Ltd.
****************************************************************************/
/**************Player One Phoenix Filter Wheel referred to as PW*****************/

#ifndef PLAYERONEPW_H
#define PLAYERONEPW_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum _PWErrors {
    PW_OK = 0,
    PW_ERROR_INVALID_INDEX,
    PW_ERROR_INVALID_HANDLE,
    PW_ERROR_INVALID_ARGU,
    PW_ERROR_NOT_OPENED,
    PW_ERROR_NOT_FOUND,
    PW_ERROR_IS_MOVING,
    PW_ERROR_POINTER,
    PW_ERROR_OPERATION_FAILED,
    PW_ERROR_FIRMWARE_ERROR
} PWErrors;

typedef enum _PWState {
    PW_STATE_CLOSED = 0,
    PW_STATE_OPENED,
    PW_STATE_MOVING
} PWState;

typedef struct _PWProperties {
    char Name[64];
    int Handle;
    int PositionCount;
    char SN[32];
    char Reserved[32];
} PWProperties;

#define MAX_NAME_LEN (24)

#ifdef __cplusplus
}
#endif

#endif
