﻿/**
	This module contains the core functionality of the vibe framework.

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.core;

public import vibe.core.driver;

import vibe.core.log;
import vibe.utils.array;
import std.conv;
import std.exception;
import std.range;
import std.variant;
import core.stdc.stdlib;
import core.thread;

import vibe.core.drivers.libevent2;
//import vibe.core.drivers.libev;

version(Posix){
	import core.sys.posix.signal;
}


/**************************************************************************************************/
/* Public functions                                                                               */
/**************************************************************************************************/

/**
	Starts the vibe event loop.

	Note that this function is usually called automatically by the vibe framework. However, if
	you provide your own main() function, you need to call it manually.

	The event loop will continue running during the whole life time of the application.
	Tasks will be started and handled from within the event loop.
*/
int start()
{
	s_eventLoopRunning = true;
	scope(exit) s_eventLoopRunning = false;
	if( auto err = s_driver.runEventLoop() != 0){
		if( err == 1 ){
			logDebug("No events active, exiting message loop.");
			return 0;
		}
		logError("Error running event loop: %d", err);
		return 1;
	}
	return 0;
}

/**
	Runs a new asynchronous task.

	task will be called synchronously from within the vibeRunTask call. It will
	continue to run until vibeYield() or any of the I/O or wait functions is
	called.
*/
Task runTask(void delegate() task)
{
	// if there is no fiber available, create one.
	if( s_availableFibersCount == 0 ){
		if( s_availableFibers.length == 0 ) s_availableFibers.length = 1024;
		logDebug("Creating new fiber...");
		s_fiberCount++;
		s_availableFibers[s_availableFibersCount++] = new CoreTask;
	}
	
	// pick the first available fiber
	auto f = s_availableFibers[--s_availableFibersCount];
	f.m_taskFunc = task;
	logDebug("initial task call");
	s_tasks ~= f;
	s_core.resumeTask(f);
	logDebug("run task out");
	return f;
}

/**
	Runs a new asynchronous task in a worker thread.

	NOTE: the interface of this function will change in the future to ensure that no unprotected
	data is passed between threads!

	NOTE: You should not use this function yet and it currently behaves just like runTask.
*/
void runWorkerTask(void delegate() task)
{
	s_driver.runWorkerTask(task);
}

/**
	Suspends the execution of the calling task to let other tasks and events be
	handled.
	
	Calling this function in short intervals is recommended if long CPU
	computations are carried out by a task. It can also be used in conjunction
	with Signals to implement cross-fiber events with no polling.
*/
void yield()
{
	assert(false);
}


/**
	Yields execution of this task until an event wakes it up again.

	Beware that the task will starve if no event wakes it up.
*/
void rawYield()
{
	s_core.yieldForEvent();
}

/**
	Suspends the execution of the calling task for the specified amount of time.
*/
void sleep(Duration timeout)
{
	auto tm = s_driver.createTimer({});
	tm.rearm(timeout);
	tm.wait();
}

/**
	Returns the active event driver
*/
EventDriver getEventDriver()
{
	return s_driver;
}


/**
	Returns a new armed timer.
*/
Timer setTimer(Duration timeout, void delegate() callback, bool periodic = false)
{
	auto tm = s_driver.createTimer(callback);
	tm.rearm(timeout, periodic);
	return tm;
}

/**
	Sets a variable specific to the calling task/fiber.
*/
void setTaskLocal(T)(string name, T value)
{
	auto self = cast(CoreTask)Fiber.getThis();
	self.m_taskLocalStorage[name] = Variant(value);
}

/**
	Returns a task/fiber specific variable.
*/
T getTaskLocal(T)(string name)
{
	auto self = cast(CoreTask)Fiber.getThis();
	auto pvar = name in self.m_taskLocalStorage;
	enforce(pvar !is null, "Accessing unset TLS variable '"~name~"'.");
	return pvar.get!T();
}

/**
	Returns a task/fiber specific variable.
*/
bool isTaskLocalSet(string name)
{
	auto self = cast(CoreTask)Fiber.getThis();
	auto pvar = name in self.m_taskLocalStorage;
	return pvar !is null;
}

/**
	A version string representing the current vibe version
*/
enum VibeVersionString = "0.7.6";


/**************************************************************************************************/
/* public types                                                                                   */
/**************************************************************************************************/

class CoreTask : Task {
	private {
		void delegate() m_taskFunc;
		Variant[string] m_taskLocalStorage;
		Exception m_exception;
	}

	this()
	{
		super(&run);
	}

	private void run()
	{
		while(true){
			while( !m_taskFunc )
				s_core.yieldForEvent();

			auto task = m_taskFunc;
			m_taskFunc = null;
			try {
				logTrace("entering task.");
				task();
				logTrace("exiting task.");
			} catch( Exception e ){
				logError("Task terminated with exception: %s", e.toString());
			}
			m_taskLocalStorage = null;
			
			// make the fiber available for the next task
			if( s_availableFibers.length <= s_availableFibersCount )
				s_availableFibers.length = 2*s_availableFibers.length;
			s_availableFibers[s_availableFibersCount++] = this;
		}
	}
}


/**************************************************************************************************/
/* private types                                                                                  */
/**************************************************************************************************/

private class VibeDriverCore : DriverCore {
	void yieldForEvent()
	{
		auto fiber = cast(CoreTask)Fiber.getThis();
		if( fiber ){
			logTrace("yield");
			Fiber.yield();
			logTrace("resume");
			auto e = fiber.m_exception;
			if( e ){
				fiber.m_exception = null;
				throw e;
			}
		} else {
			assert(!s_eventLoopRunning, "Event processing outside of a fiber should only happen before the event loop is running!?");
			if( auto err = s_driver.processEvents() != 0){
				if( err == 1 ){
					logDebug("No events registered, exiting event loop.");
					throw new Exception("No events registered in vibeYieldForEvent.");
				}
				logError("Error running event loop: %d", err);
				throw new Exception("Error waiting for events.");
			}
		}
	}

	void resumeTask(Task task, Exception event_exception = null)
	{
		CoreTask ctask = cast(CoreTask)task;
		assert(task.state == Fiber.State.HOLD, "Resuming task that is " ~ (task.state == Fiber.State.TERM ? "terminated" : "running"));

		if( event_exception ){
			extrap();
			ctask.m_exception = event_exception;
		}
		
		auto uncaught_exception = task.call(false);
		if( uncaught_exception ){
			extrap();
			assert(task.state == Fiber.State.TERM);
			logError("Task terminated with unhandled exception: %s", uncaught_exception.toString());
		}
		
		if( task.state == Fiber.State.TERM ){
			s_tasks.removeFromArray(ctask);
		}
	}
}


/**************************************************************************************************/
/* private functions                                                                              */
/**************************************************************************************************/

private {
	CoreTask[] s_tasks;
	bool s_eventLoopRunning = false;
	__gshared VibeDriverCore s_core;
	EventDriver s_driver;
	//Variant[string] s_currentTaskStorage;
	CoreTask[] s_availableFibers;
	size_t s_availableFibersCount;
	size_t s_fiberCount;
}

shared static this()
{
	version(Windows){
		logTrace("init winsock");
		// initialize WinSock2
		import std.c.windows.winsock;
		WSADATA data;
		WSAStartup(0x0202, &data);
	}
	
	logTrace("event_set_mem_functions");
	s_core = new VibeDriverCore;
	s_driver = new Libevent2Driver(s_core);
	//s_driver = new LibevDriver(s_core);
	
	version(Posix){
		// support proper shutdown using signals
		sigset_t sigset;
		sigemptyset(&sigset);
		sigaction_t siginfo;
		siginfo.sa_handler = &onSignal;
		siginfo.sa_mask = sigset;
		siginfo.sa_flags = SA_RESTART;
		sigaction(SIGINT, &siginfo, null);
		sigaction(SIGTERM, &siginfo, null);
		
		siginfo.sa_handler = &onBrokenPipe;
		sigaction(SIGPIPE, &siginfo, null);
	}
}

shared static ~this()
{
	// TODO: use destroy instead
	delete s_driver;
	delete s_core;
}

private extern(C) void extrap()
{
	logTrace("exception trap");
}

version(Posix){
	private extern(C) void onSignal(int signal)
	{
		logInfo("Received signal %d. Shutting down.", signal);

		if( s_eventLoopRunning ) s_driver.exitEventLoop();
		else exit(1);
	}
	
	private extern(C) void onBrokenPipe(int signal)
	{
	}
}
