// Written in the D programming language
// Put in the public domain by Bartosz Milewski

/**
Part of the D programming language runtime library.
Implements Object monitors used by $(D synchronized) methods and blocks

Author: Bartosz Milewski, Walter Bright
Macros:
    WIKI = Phobos/Monitor
*/

module internal.monitor;

extern (C)
{   /// C's printf function.
    int printf(const char *, ...);

    void* memcpy(void *, in void *, size_t);
    void* malloc(size_t);
    void free(void*);
}

/+
// Don't publicize it: malloc won't work with signals and slots (see std.signals)
T construct(T:Object, A...)(A args)
{
    ClassInfo info = T.classinfo;
    void * p = malloc(info.init.length);
    if (!p)
        _d_OutOfMemory();
    memcpy(p, info.init.ptr, info.init.length);
    T obj = cast(T)p;
    static if (is(typeof(obj._ctor)))
        obj._ctor(args);
    return obj;
}

void destroy(T:Object)(T obj)
{
    static if (is(typeof(obj._dtor)))
        obj._dtor();
    free(cast(void*) obj);
}
+/

/** construct a struct using malloc 
Because struct destructors don't work yet, I use artificial setup/teardown
*/
T * conStruct(T, A...)(A args)
{
    static assert(is(T == struct));
    T * p =cast(T*) malloc(T.sizeof);
    *p = T.init;
    static if (is(typeof(T.setup) == function))
        p.setup(args);
    return p;
}

/** Destruct a struct allocated using malloc */
void deStruct(T)(T * p)
{
    static if (is(typeof(p.teardown) == function))
        p.teardown();
    free(p);
}

// Global mutex used when lazily initializing Object._fatLock
OsMutex * __monitor_mutex;

/** The layout of every object header */
struct ObjectLayout
{
private:
    void * _vtable;
    FatLock * _fatLock;
}

/** For eny object return the layout of its header */
ObjectLayout * ToLayout(Object o)
{
    return cast(ObjectLayout *) cast(void *) o;
}

/** Access to the object's _fatLock */
FatLock * GetFatLock(Object o) 
{
    return ToLayout(o)._fatLock;
}

final void SetFatLock(Object o, FatLock * other)
{
    ToLayout(o)._fatLock = other;
}

/** Contains the object monitor and the array of delegates
that are used by signals and slots */
struct FatLock
{
    public  void delegate(Object) [] delegates;
    private OsMutex * mon;
    void setup() { mon = conStruct!(OsMutex)(); }
    void teardown() { deStruct(mon); }
public:
    void lock() { mon.lock; }
    void unlock() { mon.unlock; }
}

/** Called only once by a single thread during startup */
extern(C) void _STI_monitor_staticctor()
{
    __monitor_mutex = conStruct!(OsMutex)();
}

/** Called only once by a single thread during teardown */
extern(C) void _STD_monitor_staticdtor()
{
    deStruct(__monitor_mutex);
}

// De-register observers from signalers
extern(C) void _d_notify_release(Object);

/** Called by runtime when entering a synchronized block */
extern(C) 
void _d_monitorenter(Object obj)
{
    //printf("_d_monitorenter(%p), %p\n", obj, obj.__monitor);
    // Warning: data race
    if (GetFatLock(obj) is null)
    {
	__monitor_mutex.lock;
        if (GetFatLock(obj) is null) // if, in the meantime, another thread didn't set it
        {
	    SetFatLock(obj, conStruct!(FatLock));
        }
	__monitor_mutex.unlock;
    }
    GetFatLock(obj).lock;
}

/** Called by runtime when exiting a synchronized block */
extern(C) 
void _d_monitorexit(Object obj)
{
    //printf("monitor exit (%p), %p\n", obj, obj.__monitor);
    assert(GetFatLock(obj));
    GetFatLock(obj).unlock;
}

/**
 * Called by garbage collector when Object is free'd.
 */

extern(C) 
void _d_monitorrelease(Object obj)
{
    //printf("monitor release (%p), %p\n", obj, obj.__monitor);
    if (GetFatLock(obj))
    {
	_d_notify_release(obj);

        deStruct(GetFatLock(obj));
        SetFatLock(obj, null);
    }
}

/* ================================ Windows ================================= */

version (Windows)
{

private import std.c.windows.windows;

/**
Encapsulates mutual exclusion provided by the underlying operating system. 
$(D OsMutex) is re-entrant, i.e., 
the same thread may lock it multiple times. 
It must unlock it the same number of times.

Note: On Windows, it's implemented as $(D CriticalSection); on Linux, using pthreads.

*/
// replace setup/teardown with constructor/destructor for structs
struct OsMutex
{
public:
    void setup()
    {
        InitializeCriticalSection (&_critSection);
    }
    void teardown()
    {
        DeleteCriticalSection (&_critSection);
    }
    void lock() 
    {
        EnterCriticalSection (&_critSection);
    }
    void unlock() 
    { 
        LeaveCriticalSection (&_critSection);
    }
private:
    CRITICAL_SECTION    _critSection;
}

} // Windows

/* ================================ linux ================================= */
version (linux)
{

private import std.c.linux.linux;
private import std.c.linux.linuxextern;
extern(C) {
    pthread_mutexattr_t _monitors_attr;
}

// replace setup/teardown with constructor/destructor for structs
struct OsMutex
{
public:
    void setup()
    {
        pthread_mutex_init(&_mtx, &_monitors_attr);
    }
    void teardown()
    {
        pthread_mutex_destroy(&_mtx);
    }
    void lock()
    {
        pthread_mutex_lock(&_mtx);
    }
    void unlock()
    {
        pthread_mutex_unlock(&_mtx);
    }
private:
    pthread_mutex_t _mtx;
}

} // linux

