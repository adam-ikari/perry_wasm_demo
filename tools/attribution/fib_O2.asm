0000000000001450 <fib>:
    1450:	41 57                	push   %r15
    1452:	41 56                	push   %r14
    1454:	41 55                	push   %r13
    1456:	41 54                	push   %r12
    1458:	55                   	push   %rbp
    1459:	53                   	push   %rbx
    145a:	48 81 ec 88 00 00 00 	sub    $0x88,%rsp
    1461:	48 89 7c 24 10       	mov    %rdi,0x10(%rsp)
    1466:	48 83 ff 01          	cmp    $0x1,%rdi
    146a:	0f 8e 59 02 00 00    	jle    16c9 <fib+0x279>
    1470:	48 89 7c 24 08       	mov    %rdi,0x8(%rsp)
    1475:	48 c7 44 24 18 00 00 	movq   $0x0,0x18(%rsp)
    147c:	00 00 
    147e:	48 8b 7c 24 08       	mov    0x8(%rsp),%rdi
    1483:	b8 01 00 00 00       	mov    $0x1,%eax
    1488:	4c 8d 5f ff          	lea    -0x1(%rdi),%r11
    148c:	48 83 ff 02          	cmp    $0x2,%rdi
    1490:	0f 84 07 02 00 00    	je     169d <fib+0x24d>
    1496:	48 c7 44 24 20 00 00 	movq   $0x0,0x20(%rsp)
    149d:	00 00 
    149f:	4d 8d 53 ff          	lea    -0x1(%r11),%r10
    14a3:	b8 01 00 00 00       	mov    $0x1,%eax
    14a8:	49 83 fb 02          	cmp    $0x2,%r11
    14ac:	0f 84 c7 01 00 00    	je     1679 <fib+0x229>
    14b2:	48 c7 44 24 28 00 00 	movq   $0x0,0x28(%rsp)
    14b9:	00 00 
    14bb:	4c 89 5c 24 38       	mov    %r11,0x38(%rsp)
    14c0:	4d 8d 5a ff          	lea    -0x1(%r10),%r11
    14c4:	b8 01 00 00 00       	mov    $0x1,%eax
    14c9:	49 83 fa 02          	cmp    $0x2,%r10
    14cd:	0f 84 82 01 00 00    	je     1655 <fib+0x205>
    14d3:	48 c7 44 24 30 00 00 	movq   $0x0,0x30(%rsp)
    14da:	00 00 
    14dc:	4c 89 54 24 40       	mov    %r10,0x40(%rsp)
    14e1:	49 8d 6b ff          	lea    -0x1(%r11),%rbp
    14e5:	b8 01 00 00 00       	mov    $0x1,%eax
    14ea:	49 83 fb 02          	cmp    $0x2,%r11
    14ee:	0f 84 3d 01 00 00    	je     1631 <fib+0x1e1>
    14f4:	45 31 ff             	xor    %r15d,%r15d
    14f7:	4c 8d 6d ff          	lea    -0x1(%rbp),%r13
    14fb:	b8 01 00 00 00       	mov    $0x1,%eax
    1500:	48 83 fd 02          	cmp    $0x2,%rbp
    1504:	0f 84 0c 01 00 00    	je     1616 <fib+0x1c6>
    150a:	31 d2                	xor    %edx,%edx
    150c:	b8 01 00 00 00       	mov    $0x1,%eax
    1511:	49 83 fd 02          	cmp    $0x2,%r13
    1515:	0f 84 e0 00 00 00    	je     15fb <fib+0x1ab>
    151b:	4d 8d 65 fd          	lea    -0x3(%r13),%r12
    151f:	49 8d 4d fa          	lea    -0x6(%r13),%rcx
    1523:	45 31 c0             	xor    %r8d,%r8d
    1526:	4c 89 e0             	mov    %r12,%rax
    1529:	49 8d 75 fc          	lea    -0x4(%r13),%rsi
    152d:	48 83 e0 fe          	and    $0xfffffffffffffffe,%rax
    1531:	48 29 c1             	sub    %rax,%rcx
    1534:	48 8d 5e 02          	lea    0x2(%rsi),%rbx
    1538:	48 83 fe ff          	cmp    $0xffffffffffffffff,%rsi
    153c:	0f 84 a1 00 00 00    	je     15e3 <fib+0x193>
    1542:	4d 89 e1             	mov    %r12,%r9
    1545:	45 31 f6             	xor    %r14d,%r14d
    1548:	49 89 ec             	mov    %rbp,%r12
    154b:	48 8d 6b ff          	lea    -0x1(%rbx),%rbp
    154f:	b8 01 00 00 00       	mov    $0x1,%eax
    1554:	48 83 fb 02          	cmp    $0x2,%rbx
    1558:	74 69                	je     15c3 <fib+0x173>
    155a:	45 31 d2             	xor    %r10d,%r10d
    155d:	48 8d 7d ff          	lea    -0x1(%rbp),%rdi
    1561:	48 89 74 24 78       	mov    %rsi,0x78(%rsp)
    1566:	48 83 ed 02          	sub    $0x2,%rbp
    156a:	4c 89 4c 24 70       	mov    %r9,0x70(%rsp)
    156f:	48 89 4c 24 68       	mov    %rcx,0x68(%rsp)
    1574:	4c 89 54 24 60       	mov    %r10,0x60(%rsp)
    1579:	4c 89 44 24 58       	mov    %r8,0x58(%rsp)
    157e:	48 89 54 24 50       	mov    %rdx,0x50(%rsp)
    1583:	4c 89 5c 24 48       	mov    %r11,0x48(%rsp)
    1588:	e8 c3 fe ff ff       	call   1450 <fib>
    158d:	4c 8b 54 24 60       	mov    0x60(%rsp),%r10
    1592:	4c 8b 5c 24 48       	mov    0x48(%rsp),%r11
    1597:	48 8b 54 24 50       	mov    0x50(%rsp),%rdx
    159c:	4c 8b 44 24 58       	mov    0x58(%rsp),%r8
    15a1:	49 01 c2             	add    %rax,%r10
    15a4:	48 83 fd 01          	cmp    $0x1,%rbp
    15a8:	48 8b 4c 24 68       	mov    0x68(%rsp),%rcx
    15ad:	4c 8b 4c 24 70       	mov    0x70(%rsp),%r9
    15b2:	48 8b 74 24 78       	mov    0x78(%rsp),%rsi
    15b7:	7f a4                	jg     155d <fib+0x10d>
    15b9:	48 8d 43 fd          	lea    -0x3(%rbx),%rax
    15bd:	83 e0 01             	and    $0x1,%eax
    15c0:	4c 01 d0             	add    %r10,%rax
    15c3:	48 83 eb 02          	sub    $0x2,%rbx
    15c7:	49 01 c6             	add    %rax,%r14
    15ca:	48 83 fb 01          	cmp    $0x1,%rbx
    15ce:	0f 8f 77 ff ff ff    	jg     154b <fib+0xfb>
    15d4:	48 89 f3             	mov    %rsi,%rbx
    15d7:	4c 89 e5             	mov    %r12,%rbp
    15da:	4d 89 cc             	mov    %r9,%r12
    15dd:	83 e3 01             	and    $0x1,%ebx
    15e0:	4c 01 f3             	add    %r14,%rbx
    15e3:	48 83 ee 02          	sub    $0x2,%rsi
    15e7:	49 01 d8             	add    %rbx,%r8
    15ea:	48 39 f1             	cmp    %rsi,%rcx
    15ed:	0f 85 41 ff ff ff    	jne    1534 <fib+0xe4>
    15f3:	41 83 e4 01          	and    $0x1,%r12d
    15f7:	4b 8d 04 04          	lea    (%r12,%r8,1),%rax
    15fb:	49 83 ed 02          	sub    $0x2,%r13
    15ff:	48 01 c2             	add    %rax,%rdx
    1602:	49 83 fd 01          	cmp    $0x1,%r13
    1606:	0f 8f 00 ff ff ff    	jg     150c <fib+0xbc>
    160c:	48 8d 45 fd          	lea    -0x3(%rbp),%rax
    1610:	83 e0 01             	and    $0x1,%eax
    1613:	48 01 d0             	add    %rdx,%rax
    1616:	48 83 ed 02          	sub    $0x2,%rbp
    161a:	49 01 c7             	add    %rax,%r15
    161d:	48 83 fd 01          	cmp    $0x1,%rbp
    1621:	0f 8f d0 fe ff ff    	jg     14f7 <fib+0xa7>
    1627:	49 8d 43 fd          	lea    -0x3(%r11),%rax
    162b:	83 e0 01             	and    $0x1,%eax
    162e:	4c 01 f8             	add    %r15,%rax
    1631:	49 83 eb 02          	sub    $0x2,%r11
    1635:	48 01 44 24 30       	add    %rax,0x30(%rsp)
    163a:	49 83 fb 01          	cmp    $0x1,%r11
    163e:	0f 8f 9d fe ff ff    	jg     14e1 <fib+0x91>
    1644:	4c 8b 54 24 40       	mov    0x40(%rsp),%r10
    1649:	49 8d 42 fd          	lea    -0x3(%r10),%rax
    164d:	83 e0 01             	and    $0x1,%eax
    1650:	48 03 44 24 30       	add    0x30(%rsp),%rax
    1655:	49 83 ea 02          	sub    $0x2,%r10
    1659:	48 01 44 24 28       	add    %rax,0x28(%rsp)
    165e:	49 83 fa 01          	cmp    $0x1,%r10
    1662:	0f 8f 58 fe ff ff    	jg     14c0 <fib+0x70>
    1668:	4c 8b 5c 24 38       	mov    0x38(%rsp),%r11
    166d:	49 8d 43 fd          	lea    -0x3(%r11),%rax
    1671:	83 e0 01             	and    $0x1,%eax
    1674:	48 03 44 24 28       	add    0x28(%rsp),%rax
    1679:	49 83 eb 02          	sub    $0x2,%r11
    167d:	48 01 44 24 20       	add    %rax,0x20(%rsp)
    1682:	49 83 fb 01          	cmp    $0x1,%r11
    1686:	0f 8f 13 fe ff ff    	jg     149f <fib+0x4f>
    168c:	48 8b 44 24 08       	mov    0x8(%rsp),%rax
    1691:	48 83 e8 03          	sub    $0x3,%rax
    1695:	83 e0 01             	and    $0x1,%eax
    1698:	48 03 44 24 20       	add    0x20(%rsp),%rax
    169d:	48 83 6c 24 08 02    	subq   $0x2,0x8(%rsp)
    16a3:	48 8b 7c 24 08       	mov    0x8(%rsp),%rdi
    16a8:	48 01 44 24 18       	add    %rax,0x18(%rsp)
    16ad:	48 83 ff 01          	cmp    $0x1,%rdi
    16b1:	0f 8f c7 fd ff ff    	jg     147e <fib+0x2e>
    16b7:	48 8b 44 24 10       	mov    0x10(%rsp),%rax
    16bc:	83 e0 01             	and    $0x1,%eax
    16bf:	48 03 44 24 18       	add    0x18(%rsp),%rax
    16c4:	48 89 44 24 10       	mov    %rax,0x10(%rsp)
    16c9:	48 8b 44 24 10       	mov    0x10(%rsp),%rax
    16ce:	48 81 c4 88 00 00 00 	add    $0x88,%rsp
    16d5:	5b                   	pop    %rbx
    16d6:	5d                   	pop    %rbp
    16d7:	41 5c                	pop    %r12
    16d9:	41 5d                	pop    %r13
    16db:	41 5e                	pop    %r14
    16dd:	41 5f                	pop    %r15
    16df:	c3                   	ret    

