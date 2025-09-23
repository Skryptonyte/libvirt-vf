/*
 * vf_machine.h: Virtualization.Framework private API header definitions
 *
 * Copyright (C) 2025 Rayhan Faizel
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 */

#pragma once

#include <Foundation/Foundation.h>
#include <Virtualization/Virtualization.h>

/* Private VNC server object to stream graphical displays remotely */
@interface _VZVNCServer: NSObject
    -(instancetype) initWithPort: (uint32_t)port queue:(dispatch_queue_t)dispatch_queue;
    -(void) setVirtualMachine: (id)vm;
    -(void) start;
    -(void) stop;
@end
