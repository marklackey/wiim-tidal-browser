#import "PythonCatalog.h"
#import <Python/Python.h>

static BOOL AddPythonPath(PyConfig *config, NSString *path) {
    wchar_t *widePath = Py_DecodeLocale(path.fileSystemRepresentation, NULL);
    if (widePath == NULL) return NO;
    PyStatus status = PyWideStringList_Append(&config->module_search_paths, widePath);
    PyMem_RawFree(widePath);
    return !PyStatus_Exception(status);
}

static BOOL StartPython(void) {
    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    if (PyStatus_Exception(Py_PreInitialize(&preconfig))) return NO;

    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *home = [resources stringByAppendingPathComponent:@"python"];
    NSString *library = [home stringByAppendingPathComponent:@"lib/python3.14"];
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.module_search_paths_set = 1;
    config.write_bytecode = 0;
    config.site_import = 0;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home.fileSystemRepresentation);
    BOOL ready = !PyStatus_Exception(status)
        && AddPythonPath(&config, library)
        && AddPythonPath(&config, [library stringByAppendingPathComponent:@"lib-dynload"])
        && AddPythonPath(&config, [resources stringByAppendingPathComponent:@"catalog"])
        && AddPythonPath(&config, [resources stringByAppendingPathComponent:@"catalog-packages"]);
    if (ready) ready = !PyStatus_Exception(Py_InitializeFromConfig(&config));
    PyConfig_Clear(&config);
    if (ready) PyEval_SaveThread();
    return ready;
}

NSData *ReadTIDALCatalog(NSString *action, NSData *request, NSString *dataDirectory) {
    static dispatch_once_t once;
    static BOOL ready;
    dispatch_once(&once, ^{ ready = StartPython(); });
    if (!ready) return nil;

    NSData *response = nil;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *module = PyImport_ImportModule("catalog_bridge");
    PyObject *handle = module ? PyObject_GetAttrString(module, "handle") : NULL;
    PyObject *result = handle ? PyObject_CallFunction(handle, "sy#s", action.UTF8String, request.bytes,
                                                     (Py_ssize_t)request.length, dataDirectory.fileSystemRepresentation) : NULL;
    if (result && PyBytes_Check(result)) {
        response = [NSData dataWithBytes:PyBytes_AS_STRING(result) length:PyBytes_GET_SIZE(result)];
    }
    Py_XDECREF(result);
    Py_XDECREF(handle);
    Py_XDECREF(module);
    PyErr_Clear();
    PyGILState_Release(gil);
    return response;
}
