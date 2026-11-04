package com.celltower.cell_tower_monitor;

interface IPrivilegedRadio {
    // Transaction code defined by the Shizuku server: the service must clean
    // itself up here, because unbinding does not kill the process.
    void destroy() = 16777114;

    // Everything the app asks for, as JSON: component carriers and the QCI of
    // the active data bearer. One call, so a refresh is a single IPC.
    String readCarrierDetail(int subId) = 2;
}
