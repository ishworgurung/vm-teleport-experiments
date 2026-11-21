/* _ckpt: lets a Python script on WASI ask the host to checkpoint it.
 *
 * Built into python.wasm through Modules/Setup.local (WASI has no dlopen, so
 * extension modules must be static). `_ckpt.checkpoint()` calls the host
 * import `ckpt.checkpoint`. After the Asyncify pass, that import can unwind
 * the whole C stack (main, the eval loop, this function) into the buffer
 * below, and a host on another ISA can rewind it: the call then returns as
 * if nothing had happened, and the script carries on.
 *
 * The buffer and the two functions the host looks for are exported by name
 * (export_name), so no linker flags are needed for them.
 */
/* The Python C API. */
#include "Python.h"

/* Only for the WASI build.  The other branch (#else) is for the native build. */
#ifdef __wasi__

/* Import the function `checkpoint` from the host module `ckpt`.  The host supplies it when it loads the Wasm module. */
__attribute__((import_module("ckpt"), import_name("checkpoint")))
/* Declare it.  It takes nothing and returns nothing. */
extern void ckpt_host_checkpoint(void);

/* Asyncify saves each frame's locals here. 1 MiB is generous: the C stack at
 * the checkpoint is main -> Py_RunMain -> ... -> the eval loop -> here. */
/* The size of the buffer for the saved stack: 1 MiB. */
#define CKPT_BUFFER_SIZE (1024 * 1024)
/* The buffer itself.  It is aligned to 16 bytes. */
static unsigned char ckpt_buffer_data[CKPT_BUFFER_SIZE] __attribute__((aligned(16)));

/* Export this function under the name ckpt_buffer, so that the host can find it by name. */
__attribute__((export_name("ckpt_buffer")))
/* Return the address of the buffer.  In Wasm, an address is an integer. */
int ckpt_buffer(void) { return (int)(unsigned long)ckpt_buffer_data; }

/* Export this function under the name ckpt_buffer_size. */
__attribute__((export_name("ckpt_buffer_size")))
/* Return the size of the buffer. */
int ckpt_buffer_size(void) { return CKPT_BUFFER_SIZE; }

/* The Python function _ckpt.checkpoint().  It returns a PyObject pointer. */
static PyObject *
/* `module` is the module object.  The second argument is unused: the function takes none. */
ckpt_checkpoint(PyObject *module, PyObject *Py_UNUSED(ignored))
{
    /* Call the host.  After the Asyncify pass, this call can unwind the C stack into the buffer, and a later rewind returns from it as if nothing happened. */
    ckpt_host_checkpoint();
    /* Return Python's None. */
    Py_RETURN_NONE;
}

#else  /* the native "build Python" also compiles Setup.local */

/* The same function for a native build, where no host exists. */
static PyObject *
ckpt_checkpoint(PyObject *module, PyObject *Py_UNUSED(ignored))
{
    /* Raise a RuntimeError in Python, with a message. */
    PyErr_SetString(PyExc_RuntimeError, "_ckpt works only in a WASI build");
    /* Return NULL: that tells Python that an exception is set. */
    return NULL;
}

/* End of the choice between the WASI build and the native build. */
#endif

/* The list of functions that the module offers to Python. */
static PyMethodDef ckpt_methods[] = {
    /* The function `checkpoint`: C function, takes no arguments, with a help text. */
    {"checkpoint", ckpt_checkpoint, METH_NOARGS,
     "Pause here; the host may resume this process on another machine."},
    /* The end marker of the list. */
    {NULL, NULL, 0, NULL},
};

/* Module slots: extra settings. */
static PyModuleDef_Slot ckpt_slots[] = {
    /* Say that this module does not need the global interpreter lock. */
    {Py_mod_gil, Py_MOD_GIL_NOT_USED},
    /* The end marker of the list. */
    {0, NULL},
};

/* The description of the module. */
static struct PyModuleDef ckpt_module = {
    /* Required first field of every module description. */
    PyModuleDef_HEAD_INIT,
    /* The module name. */
    .m_name = "_ckpt",
    /* Its help text. */
    .m_doc = "Checkpoint hook for the VM teleport experiments.",
    /* The module keeps no state of its own. */
    .m_size = 0,
    /* The list of its functions. */
    .m_methods = ckpt_methods,
    /* The list of its slots. */
    .m_slots = ckpt_slots,
};

/* Python calls this function when it imports _ckpt.  The name is PyInit_ plus the module name. */
PyMODINIT_FUNC
PyInit__ckpt(void)
{
    /* Create the module from its description. */
    return PyModuleDef_Init(&ckpt_module);
}
