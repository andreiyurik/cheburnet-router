<script>
	import { cn } from "$lib/utils.js";

	let {
		ref = $bindable(null),
		class: className,
		children,
		...restProps
	} = $props();
</script>

<div
	bind:this={ref}
	role="list"
	data-slot="item-group"
	class={cn("group/item-group flex flex-col", className)}
	{...restProps}
>
	{@render children?.()}
</div>
