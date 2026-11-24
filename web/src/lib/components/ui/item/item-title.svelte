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
	data-slot="item-title"
	class={cn("flex w-fit items-center gap-2 text-sm leading-snug font-medium", className)}
	{...restProps}
>
	{@render children?.()}
</div>
