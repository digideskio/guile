;;; installed-scm-file

;;;; 	Copyright (C) 1996 Free Software Foundation, Inc.
;;;; 
;;;; This program is free software; you can redistribute it and/or modify
;;;; it under the terms of the GNU General Public License as published by
;;;; the Free Software Foundation; either version 2, or (at your option)
;;;; any later version.
;;;; 
;;;; This program is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;;; GNU General Public License for more details.
;;;; 
;;;; You should have received a copy of the GNU General Public License
;;;; along with this software; see the file COPYING.  If not, write to
;;;; the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.
;;;; 


;;; Expect: a macro for selecting actions based on what it reads from a port.
;;; The idea is from Don Libes' expect based on Tcl.
;;; This version by Gary Houston incorporating ideas from Aubrey Jaffer.


(define expect-port #f)
(define expect-timeout #f)
(define expect-timeout-proc #f)
(define expect-eof-proc #f)
(define expect-char-proc #f)

;;; expect: each test is a procedure which is applied to the accumulating
;;; string.
(defmacro expect clauses
  (let ((s (gentemp))
	(c (gentemp))
	(port (gentemp))
	(timeout (gentemp)))
    `(let ((,s "")
	   (,port (or expect-port (current-input-port)))
	   (,timeout (if expect-timeout
			 (+ (* expect-timeout internal-time-units-per-second)
			    (get-internal-real-time))
			 #f)))
       (let next-char ()
	 (if (and expect-timeout
		  (or (>= (get-internal-real-time) ,timeout)
		      (and (not (char-ready? ,port))
			   (not (expect-select ,port ,timeout)))))
	     (if expect-timeout-proc
		 (expect-timeout-proc ,s)
		 #f)
	     (let ((,c (read-char ,port)))
	       (if expect-char-proc
		   (expect-char-proc ,c))
	       (cond ((eof-object? ,c)
		      (if expect-eof-proc
			  (expect-eof-proc ,s)
			  #f))
		     (else
		      (set! ,s (string-append ,s (string ,c)))
		      (cond
		       ,@(let next-expr ((tests (map car clauses))
					   (exprs (map cdr clauses))
					   (body ()))
			   (cond
			    ((null? tests)
			     (reverse body))
			    (else
			     (next-expr
			      (cdr tests)
			      (cdr exprs)
			      (cons
			       `((,(car tests) ,s)
				 ,@(cond ((null? (car exprs))
					  ())
					 ((eq? (caar exprs) '=>)
					  (if (not (= (length (car exprs))
						      2))
					      (scm-error 'misc-error
							 "expect"
							 "bad recipient: %S"
							 (list (car exprs))
							 #f)
					      `((apply ,(cadar exprs)
						       (,(car tests) ,s)))))
					 (else 
					  (car exprs))))
			       body)))))
		       (else (next-char)))))))))))

;;; the regexec front-end to expect:
;;; each test must evaluate to a regular expression.
(defmacro expect-strings clauses
  `(let ,@(let next-test ((tests (map car clauses))
			  (exprs (map cdr clauses))
			  (defs ())
			  (body ()))
	    (cond ((null? tests)
		   (list (reverse defs) `(expect ,@(reverse body))))
		  (else
		   (let ((rxname (gentemp)))
		     (next-test (cdr tests)
				(cdr exprs)
				(cons `(,rxname (regcomp ,(car tests)
							 REG_NEWLINE))
				      defs)
				(cons `((lambda (s)
					  (regexec ,rxname s ""))
					,@(car exprs))
				      body))))))))

;;; simplified select: returns #t if input is waiting or #f if timed out.
;;; timeout is absolute in terms of get-internal-real-time.
(define (expect-select port timeout)
  (let* ((relative (- timeout (get-internal-real-time)))
	 (relative-s (inexact->exact
		      (floor (/ relative internal-time-units-per-second))))
	 (relative-ms (inexact->exact
		       (round (/ (* (- relative relative-s) 1000)
				 internal-time-units-per-second)))))
    (and (> relative 0)
	 (pair? (car (select (list port) () ()
			     relative-s
			     relative-ms))))))
