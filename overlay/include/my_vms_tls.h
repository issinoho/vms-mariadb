/* Copyright (c) 2026, the vms-mariadb contributors.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; version 2 of the License.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335  USA */

/*
  Thread-local storage for OpenVMS.

  VSI C++ (clang 10) rejects thread_local, __thread and _Thread_local
  ("OpenVMS does not currently support thread_local"; -femulated-tls does
  not help).  my_thread_local<T> gives each thread its own T behind a
  pthread key: created (value-initialised) on first use in a thread and
  destroyed when the thread exits.  Pointers, integers and enums that fit
  in a void* are kept in the key's slot itself, without an allocation.

  Use it for objects of static storage duration only (namespace scope,
  class static members, function-local statics):

    static thread_local THD *THR_THD;        ->  static my_thread_local<THD*> THR_THD;
    THR_THD= thd;  THD *t= THR_THD;           (unchanged)
    static thread_local String tmp;          ->  static my_thread_local<String> tmp_tls;
                                                 String &tmp= tmp_tls.get();
*/

#ifndef MY_VMS_TLS_INCLUDED
#define MY_VMS_TLS_INCLUDED

#ifdef __cplusplus
#include <pthread.h>
#include <stdint.h>
#include <type_traits>

template <typename T, bool in_slot=
          (std::is_pointer<T>::value || std::is_integral<T>::value ||
           std::is_enum<T>::value) && sizeof(T) <= sizeof(void *)>
class my_thread_local;

/* Pointers, integers, enums: the value lives in the key's slot. */
template <typename T>
class my_thread_local<T, true>
{
  pthread_key_t key;
public:
  my_thread_local() { pthread_key_create(&key, NULL); }
  ~my_thread_local() { pthread_key_delete(key); }
  T get() const
  { return (T) (uintptr_t) pthread_getspecific(key); }
  void set(T v) { pthread_setspecific(key, (void *) (uintptr_t) v); }
  operator T() const { return get(); }
  my_thread_local &operator=(T v) { set(v); return *this; }
  T operator->() const { return get(); }
  my_thread_local(const my_thread_local &)= delete;
  my_thread_local &operator=(const my_thread_local &)= delete;
};

/* Anything else: one heap object per thread, deleted at thread exit. */
template <typename T>
class my_thread_local<T, false>
{
  pthread_key_t key;
  static void destroy(void *p) { delete static_cast<T *>(p); }
public:
  my_thread_local() { pthread_key_create(&key, destroy); }
  ~my_thread_local() { pthread_key_delete(key); }
  T &get()
  {
    T *p= static_cast<T *>(pthread_getspecific(key));
    if (!p)
    {
      p= new T();
      pthread_setspecific(key, p);
    }
    return *p;
  }
  operator T &() { return get(); }
  T *operator->() { return &get(); }
  my_thread_local &operator=(const T &v) { get()= v; return *this; }
  my_thread_local(const my_thread_local &)= delete;
  my_thread_local &operator=(const my_thread_local &)= delete;
};

#endif /* __cplusplus */
#endif /* MY_VMS_TLS_INCLUDED */
